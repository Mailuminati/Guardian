// Mailuminati Guardian
// Copyright (C) 2025 Simon Bressier
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

package main

import (
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"sync/atomic"
	"time"

	"github.com/glaslos/tlsh"
	"github.com/jhillyerd/enmime"
)

// --- Internal TLSH logic ---

func computeLocalTLSH(content string) (string, error) {
	goHashStruct, err := tlsh.HashBytes([]byte(content))
	if err != nil {
		return "", err
	}
	// "T1" prefix + Uppercase
	return "T1" + strings.ToUpper(goHashStruct.String()), nil
}

// computeDistance computes the distance between two hashes locally
func computeDistance(d1, d2 string, includeLen bool, threshold int) (int, error) {
	// Strip T1 prefix if present, as ParseStringToTlsh expects raw hex
	d1 = strings.TrimPrefix(d1, "T1")
	d2 = strings.TrimPrefix(d2, "T1")

	t1, err := tlsh.ParseStringToTlsh(d1)
	if err != nil {
		return 0, err
	}
	t2, err := tlsh.ParseStringToTlsh(d2)
	if err != nil {
		return 0, err
	}

	// Note: glaslos/tlsh Diff includes length.
	dist := t1.Diff(t2)

	return dist, nil
}

// computeDistanceBatch computes distances in batch (Batch)
func computeDistanceBatch(ref string, digests []string, ids []string, includeLen bool) (map[string]int, error) {
	if len(digests) != len(ids) {
		return nil, errors.New("digests and ids length mismatch")
	}

	ref = strings.TrimPrefix(ref, "T1")
	tRef, err := tlsh.ParseStringToTlsh(ref)
	if err != nil {
		return nil, err
	}

	results := make(map[string]int)
	for i, digest := range digests {
		d := strings.TrimPrefix(digest, "T1")
		t, err := tlsh.ParseStringToTlsh(d)
		if err != nil {
			continue // Skip invalid hashes
		}

		dist := tRef.Diff(t)
		results[ids[i]] = dist
	}
	return results, nil
}

var (
	reImgSrcN   = regexp.MustCompile(`(?i)<img([^>]*?)src="[^"]*"([^>]*?)>`)
	reHex8      = regexp.MustCompile(`[0-9a-fA-F]{8,}`)
	reDigit6    = regexp.MustCompile(`\d{6,}`)
	reStyleAttr = regexp.MustCompile(`(?i)\s*style\s*=\s*"[^"]*"`)
	reTrackers  = regexp.MustCompile(`(?i)([?&])(utm_[^=&]+|gclid|fbclid|mc_eid|mc_cid)=[^&\s"'>]+`)
	reSpaces    = regexp.MustCompile(`[ \t]+`)
	reNewlines  = regexp.MustCompile(`\r?\n{2,}`)
)

func normalizeEmailBody(text, html string) string {
	body := text + "\n\n" + html
	body = strings.TrimSpace(body)

	body = reImgSrcN.ReplaceAllString(body, `<img${1}src="imgurl"${2}>`)
	body = reHex8.ReplaceAllString(body, "****")
	body = reDigit6.ReplaceAllString(body, "****")
	body = reStyleAttr.ReplaceAllString(body, "")
	body = reTrackers.ReplaceAllString(body, "$1")
	body = strings.ToLower(body)
	body = reSpaces.ReplaceAllString(body, " ")
	body = reNewlines.ReplaceAllString(body, "\n\n")

	return body
}

func extractBands_6_3(sig string) []string {
	const (
		headerLen = 8
		bodyLen   = 64
		window    = 6
		stride    = 3
	)
	if len(sig) < headerLen+bodyLen {
		return []string{}
	}
	core := sig[headerLen : headerLen+bodyLen]
	bands := make([]string, 0, 20)
	idx := 1
	for pos := 0; pos+window <= bodyLen; pos += stride {
		band := core[pos : pos+window]
		bands = append(bands, fmt.Sprintf("%d:%s", idx, band))
		idx++
	}
	return bands
}

func storeScanResult(env *enmime.Envelope, hashes []string) {
	msgID := env.GetHeader("Message-ID")
	if msgID == "" {
		return
	}

	hasher := sha1.New()
	hasher.Write([]byte(msgID))
	sha1Hash := hex.EncodeToString(hasher.Sum(nil))

	result := ScanResult{Hashes: hashes, Timestamp: time.Now().Unix()}
	resultBytes, _ := json.Marshal(result)

	key := "mi:msgid:" + sha1Hash

	// Use a timeout context to prevent goroutine leaks if Redis hangs
	// This was causing linear growth of goroutines under load
	opCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rdb.Set(opCtx, key, resultBytes, 7*24*time.Hour)
}

func callOracleDecision(sig string) AnalysisResult {
	cacheKey := "mi:oracle_cache:" + sig
	if cached, err := rdb.Get(ctx, cacheKey).Result(); err == nil {
		var res AnalysisResult
		if json.Unmarshal([]byte(cached), &res) == nil {
			if res.Action == "spam" {
				atomic.AddInt64(&cachedPositiveCount, 1)
				promCacheHits.WithLabelValues("positive").Inc()
			} else {
				atomic.AddInt64(&cachedNegativeCount, 1)
				promCacheHits.WithLabelValues("negative").Inc()
			}
			return res
		}
	}

	payload, _ := json.Marshal(map[string]string{
		"node_id":         nodeID,
		"email_body_hash": sig,
	})

	client := &http.Client{Timeout: 4 * time.Second}
	resp, err := client.Post(oracleURL+"/analyze", "application/json", bytes.NewBuffer(payload))
	if err != nil {
		return AnalysisResult{Action: "allow", ProximityMatch: true}
	}
	defer resp.Body.Close()

	var res struct {
		Result AnalysisResult `json:"result"`
	}
	json.NewDecoder(resp.Body).Decode(&res)

	if res.Result.Action != "" {
		cacheDuration := 5 * time.Minute
		if res.Result.Action == "spam" {
			// For SPAM: Store exactly like local learns (LSH bands) + Exact Cache
			cacheDuration = 1 * time.Hour

			// 1. Exact Cache (Fast path)
			data, _ := json.Marshal(res.Result)
			rdb.Set(ctx, cacheKey, data, cacheDuration)

			// 2. LSH Bands (Proximity path)
			bands := extractBands_6_3(sig)
			pipe := rdb.Pipeline()
			for _, band := range bands {
				key := OracleCacheFragPrefix + band
				pipe.SAdd(ctx, key, sig)
				pipe.Expire(ctx, key, cacheDuration)
			}
			pipe.Exec(ctx)
		} else {
			// For HAM/Others: Store only exact cache
			data, _ := json.Marshal(res.Result)
			rdb.Set(ctx, cacheKey, data, cacheDuration)
		}
		return res.Result
	}

	return AnalysisResult{Action: "allow", ProximityMatch: true}
}
