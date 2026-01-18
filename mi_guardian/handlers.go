package main

import (
	"bytes"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/go-redis/redis/v8"
	"github.com/jhillyerd/enmime"
)

// --- Handlers ---

func analyzeHandler(w http.ResponseWriter, r *http.Request) {
	atomic.AddInt64(&scanCount, 1)
	promScanned.Inc()

	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}

	bodyBytes, err := io.ReadAll(io.LimitReader(r.Body, MaxProcessSize))
	if err != nil {
		http.Error(w, "Error reading body", http.StatusInternalServerError)
		return
	}

	env, err := enmime.ReadEnvelope(bytes.NewReader(bodyBytes))
	if err != nil {
		http.Error(w, "Invalid MIME", http.StatusBadRequest)
		return
	}

	signatures := []string{}

	// get the message-id and subject for logging
	messageID := env.GetHeader("Message-ID")
	subject := env.GetHeader("Subject")

	// 1. Analyze text body (Standard strategy)
	combinedBody := normalizeEmailBody(env.Text, env.HTML)
	if len(combinedBody) > 100 {
		if sig, err := computeLocalTLSH(combinedBody); err == nil {
			signatures = append(signatures, sig)
		} else {
			log.Printf("[Mailuminati] Failed to compute TLSH for body: %v", err)
		}
	}

	// 2. Extra Hash: Raw Body (HTML + Text concatenated, no normalization)
	rawBody := env.Text + env.HTML
	if len(rawBody) > 100 {
		if sig, err := computeLocalTLSH(rawBody); err == nil {
			signatures = append(signatures, sig)
		}
	}

	// 4. Analyze significant attachments
	for _, att := range env.Attachments {
		isImg := strings.HasPrefix(att.ContentType, "image/")
		if (isImg && len(att.Content) > MinVisualSize) || (!isImg && len(att.Content) > 128) {
			if sig, err := computeLocalTLSH(string(att.Content)); err == nil {
				signatures = append(signatures, sig)
			} else {
				log.Printf("[Mailuminati] Failed to compute TLSH for attachment '%s': %v", att.FileName, err)
			}
		}
	}

	go storeScanResult(env, signatures)

	var finalResult AnalysisResult = AnalysisResult{Action: "allow", ProximityMatch: false}

	// 3. Collision search
	for _, sig := range signatures {
		// Step 1: Check oracle decision cache
		cacheKey := "mi:oracle_cache:" + sig
		if cached, err := rdb.Get(ctx, cacheKey).Result(); err == nil {
			var res AnalysisResult
			if json.Unmarshal([]byte(cached), &res) == nil && res.Action == "spam" {
				finalResult = res
				atomic.AddInt64(&cachedPositiveCount, 1)
				promCacheHits.WithLabelValues("positive").Inc()
				goto endAnalysis // Final verdict; stop everything
			}
		}

		bands := extractBands_6_3(sig)
		var pipe redis.Pipeliner

		// Declare here to avoid "goto jumps over declaration"
		var matchCount int
		var oracleCmds []*redis.IntCmd

		// Step 1.5: Oracle Cache Proximity Lookup (Spam variations from recent queries)
		oracleCacheBandsKeys := []string{}
		pipe = rdb.Pipeline()
		ocCmds := make(map[string]*redis.IntCmd)
		for _, b := range bands {
			key := OracleCacheFragPrefix + b
			ocCmds[key] = pipe.Exists(ctx, key)
		}
		pipe.Exec(ctx)

		for key, cmd := range ocCmds {
			if cmd.Val() > 0 {
				oracleCacheBandsKeys = append(oracleCacheBandsKeys, key)
			}
		}

		if len(oracleCacheBandsKeys) >= 4 {
			var ocHashes []string
			pipe = rdb.Pipeline()
			hashCmds := make(map[string]*redis.StringSliceCmd)
			for _, key := range oracleCacheBandsKeys {
				hashCmds[key] = pipe.SMembers(ctx, key)
			}
			pipe.Exec(ctx)

			seenHashes := make(map[string]struct{})
			for _, cmd := range hashCmds {
				for _, hash := range cmd.Val() {
					if _, seen := seenHashes[hash]; !seen {
						ocHashes = append(ocHashes, hash)
						seenHashes[hash] = struct{}{}
					}
				}
			}

			if len(ocHashes) > 0 {
				distances, err := computeDistanceBatch(sig, ocHashes, ocHashes, false)
				if err == nil {
					for hash, dist := range distances {
						if dist <= 70 {
							log.Printf("[Mailuminati] Oracle Cache Proximity Match! Message-ID: %s | Subject: %s | Signature: %s | Match: %s | Distance: %d", messageID, subject, sig, hash, dist)
							finalResult = AnalysisResult{Action: "spam", Label: "oracle_cache_match", ProximityMatch: true, Distance: dist}
							atomic.AddInt64(&cachedPositiveCount, 1)
							promCacheHits.WithLabelValues("positive").Inc()
							goto endAnalysis
						}
					}
				}
			}
		}

		// Step 2: Local learning lookup
		localMatchBandsKeys := []string{}
		pipe = rdb.Pipeline()
		localCmds := make(map[string]*redis.IntCmd)
		for _, b := range bands {
			key := LocalFragPrefix + b
			localCmds[key] = pipe.Exists(ctx, key)
		}
		pipe.Exec(ctx)

		for key, cmd := range localCmds {
			if cmd.Val() > 0 {
				localMatchBandsKeys = append(localMatchBandsKeys, key)
			}
		}

		if len(localMatchBandsKeys) >= 4 {
			pipe = rdb.Pipeline()
			for _, key := range localMatchBandsKeys {
				pipe.Expire(ctx, key, localRetentionDuration)
			}
			pipe.Exec(ctx)

			var localHashes []string
			pipe = rdb.Pipeline()
			hashCmds := make(map[string]*redis.StringSliceCmd)
			for _, key := range localMatchBandsKeys {
				hashCmds[key] = pipe.SMembers(ctx, key)
			}
			pipe.Exec(ctx)

			seenHashes := make(map[string]struct{})
			for _, cmd := range hashCmds {
				for _, hash := range cmd.Val() {
					if _, seen := seenHashes[hash]; !seen {
						localHashes = append(localHashes, hash)
						seenHashes[hash] = struct{}{}
					}
				}
			}

			if len(localHashes) > 0 {
				distances, err := computeDistanceBatch(sig, localHashes, localHashes, false)
				if err == nil {
					isLocalSpam := false
					for hash, dist := range distances {
						if dist <= 70 {
							// Check score
							scoreKey := LocalScorePrefix + hash
							scoreVal, _ := rdb.Get(ctx, scoreKey).Int64()

							if scoreVal > 0 {
								log.Printf("[Mailuminati] Local spam detected! Message-ID: %s | Subject: %s | Signature: %s | Match: %s | Score: %d", messageID, subject, sig, hash, scoreVal)
								finalResult = AnalysisResult{Action: "spam", Label: "local_spam", ProximityMatch: true, Distance: dist}
								atomic.AddInt64(&localSpamCount, 1)
								promLocalMatch.Inc()
								isLocalSpam = true
								break // A single match is enough
							}
						}
					}
					if isLocalSpam {
						goto nextSignature // Local spam verdict; move to next signature
					}
				}
			}
			// If we reach here, distances were > 70
			finalResult.ProximityMatch = true
			goto nextSignature // Stop here for this signature, as requested
		}

		// Step 3: Band-based collision search (Oracle LSH)
		matchCount = 0
		pipe = rdb.Pipeline()
		oracleCmds = make([]*redis.IntCmd, len(bands))
		for i, b := range bands {
			oracleCmds[i] = pipe.Exists(ctx, FragKeyPrefix+b)
		}
		pipe.Exec(ctx)

		for _, cmd := range oracleCmds {
			if cmd.Val() > 0 {
				matchCount++
			}
		}

		if matchCount >= 4 {
			oracleVerdict := callOracleDecision(sig) // Call the oracle only here
			if oracleVerdict.Action == "spam" {
				log.Printf("[Mailuminati] Oracle spam detected! Message-ID: %s | Subject: %s | Signature: %s", messageID, subject, sig)
				finalResult = oracleVerdict
				atomic.AddInt64(&spamConfirmedCount, 1)
				promOracleMatch.WithLabelValues("complete").Inc()
				break // Final verdict; stop everything
			} else {
				log.Printf("[Mailuminati] Oracle partial match. Message-ID: %s | Subject: %s | Signature: %s", messageID, subject, sig)
				finalResult.ProximityMatch = true
				atomic.AddInt64(&partialMatchCount, 1)
				promOracleMatch.WithLabelValues("partial").Inc()
			}
		}

	nextSignature:
		// If we have a spam verdict (local or oracle), we can stop
		if finalResult.Action == "spam" {
			break
		}
	}

endAnalysis:
	w.Header().Set("Content-Type", "application/json")
	response := struct {
		Action         string   `json:"action"`
		Label          string   `json:"label,omitempty"`
		ProximityMatch bool     `json:"proximity_match"`
		Distance       int      `json:"distance,omitempty"`
		Hashes         []string `json:"hashes,omitempty"`
	}{
		Action:         finalResult.Action,
		Label:          finalResult.Label,
		ProximityMatch: finalResult.ProximityMatch,
		Distance:       finalResult.Distance,
		Hashes:         signatures,
	}

	respBytes, _ := json.Marshal(response)
	w.WriteHeader(http.StatusOK)
	w.Write(respBytes)
}

func reportHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}

	var reqBody struct {
		MessageID  string `json:"message-id"`
		ReportType string `json:"report_type"`
	}

	if err := json.NewDecoder(r.Body).Decode(&reqBody); err != nil {
		http.Error(w, "Invalid JSON body", http.StatusBadRequest)
		return
	}

	hasher := sha1.New()
	hasher.Write([]byte(reqBody.MessageID))
	sha1Hash := hex.EncodeToString(hasher.Sum(nil))

	// Prevent duplicate reports for the same type
	reportKey := "mi:rpt:" + sha1Hash + ":" + reqBody.ReportType
	if added, err := rdb.SetNX(ctx, reportKey, "1", 24*time.Hour).Result(); err != nil {
		http.Error(w, "Redis error", http.StatusInternalServerError)
		return
	} else if !added {
		log.Printf("[Mailuminati] Duplicate %s report ignored for Message-ID: %s", reqBody.ReportType, reqBody.MessageID)
		w.WriteHeader(http.StatusConflict)
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"duplicate","message":"Already reported"}`))
		return
	}

	key := "mi:msgid:" + sha1Hash

	val, err := rdb.Get(ctx, key).Result()
	if err == redis.Nil {
		http.Error(w, "No scan data found", http.StatusNotFound)
		return
	}

	var scanData ScanResult
	json.Unmarshal([]byte(val), &scanData)

	// Check if we have hashes to report, else return error
	if len(scanData.Hashes) == 0 {
		http.Error(w, "No hashes to report", http.StatusBadRequest)
		return
	}

	// --- Local learning ---
	skipOracleReport := false

	if reqBody.ReportType == "spam" || reqBody.ReportType == "ham" {
		log.Printf("[Mailuminati] Processing %s report for Message-ID: %s", reqBody.ReportType, reqBody.MessageID)

		for _, hash := range scanData.Hashes {
			bands := extractBands_6_3(hash)

			// 1. Identify candidates using LSH
			pipe := rdb.Pipeline()
			localCmds := make(map[string]*redis.IntCmd)
			for _, b := range bands {
				key := LocalFragPrefix + b
				localCmds[key] = pipe.Exists(ctx, key)
			}
			pipe.Exec(ctx)

			matchingBandsKeys := []string{}
			for key, cmd := range localCmds {
				if cmd.Val() > 0 {
					matchingBandsKeys = append(matchingBandsKeys, key)
				}
			}

			var bestMatchHash string
			var bestMatchDist int = 9999

			if len(matchingBandsKeys) >= 4 {
				// Get candidates
				pipe = rdb.Pipeline()
				hashCmds := make(map[string]*redis.StringSliceCmd)
				for _, key := range matchingBandsKeys {
					hashCmds[key] = pipe.SMembers(ctx, key)
				}
				pipe.Exec(ctx)

				candidates := make(map[string]struct{})
				for _, cmd := range hashCmds {
					for _, h := range cmd.Val() {
						candidates[h] = struct{}{}
					}
				}

				candidateList := []string{}
				for h := range candidates {
					candidateList = append(candidateList, h)
				}

				if len(candidateList) > 0 {
					// Compute distances
					distances, err := computeDistanceBatch(hash, candidateList, candidateList, false)
					if err == nil {
						for h, dist := range distances {
							if dist < bestMatchDist {
								bestMatchDist = dist
								bestMatchHash = h
							}
						}
					}
				}
			}

			// Decision Logic
			targetHash := hash // Default: the reported hash itself
			if bestMatchDist <= 70 {
				targetHash = bestMatchHash
			}

			scoreKey := LocalScorePrefix + targetHash

			if reqBody.ReportType == "spam" {
				if bestMatchDist <= 70 {
					// Already known locally
					skipOracleReport = true
				}

				// Increment score
				// Use atomic load for safe concurrent access during reload
				currentSpamWeight := atomic.LoadInt64(&spamWeight)
				newScore, _ := rdb.IncrBy(ctx, scoreKey, currentSpamWeight).Result()

				// Refresh/Add bands
				pipe := rdb.Pipeline()
				targetBands := extractBands_6_3(targetHash)
				for _, band := range targetBands {
					key := LocalFragPrefix + band
					pipe.SAdd(ctx, key, targetHash)
					pipe.Expire(ctx, key, localRetentionDuration)
				}
				pipe.Expire(ctx, scoreKey, localRetentionDuration)
				pipe.Exec(ctx)
				log.Printf("[Mailuminati] Learned spam hash: %s (Score: %d)", targetHash, newScore)

			} else if reqBody.ReportType == "ham" {
				if bestMatchDist <= 70 {
					// Found a corresponding spam entry to punish
					currentHamWeight := atomic.LoadInt64(&hamWeight)
					newScore, _ := rdb.DecrBy(ctx, scoreKey, currentHamWeight).Result()
					log.Printf("[Mailuminati] Ham report for hash: %s (Score: %d)", targetHash, newScore)

					// Refresh TTL (keep it alive even if negative)
					rdb.Expire(ctx, scoreKey, localRetentionDuration)
				}
			}
		}
	}
	// --- End local learning ---

	if reqBody.ReportType == "spam" && skipOracleReport {
		log.Printf("[Mailuminati] Skip Oracle report for Message-ID: %s (Already known)", reqBody.MessageID)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK) // Return 200 OK
		w.Write([]byte(`{"status":"skipped_oracle","reason":"known_locally"}`))
		return
	}

	payload, _ := json.Marshal(map[string]interface{}{
		"node_id":     nodeID,
		"signatures":  scanData.Hashes,
		"report_type": reqBody.ReportType,
	})

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Post(oracleURL+"/report", "application/json", bytes.NewBuffer(payload))
	if err != nil {
		http.Error(w, "Oracle unreachable", http.StatusServiceUnavailable)
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	w.Write(body)
}

func statusHandler(w http.ResponseWriter, r *http.Request) {
	// Used by the installer post-start check: must return node_id and current_seq when healthy.
	if nodeID == "" {
		nodeID = initNode()
	}

	currentSeq, err := rdb.Get(ctx, MetaVer).Int()
	if err != nil && err != redis.Nil {
		http.Error(w, "Redis unavailable", http.StatusServiceUnavailable)
		return
	}
	if err == redis.Nil {
		currentSeq = 0
	}

	resp := map[string]interface{}{
		"node_id":     nodeID,
		"current_seq": currentSeq,
		"version":     EngineVersion,
	}
	respBytes, _ := json.Marshal(resp)

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	w.Write(respBytes)
}

func logRequestHandler(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		log.Printf("[Mailuminati] Request: %s %s", r.Method, r.URL.Path)
		next.ServeHTTP(w, r)
	}
}
