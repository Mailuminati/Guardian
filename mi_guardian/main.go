// Copyright (c) 2025 Simon Bressier
// Licensed under the MIT License.

package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/glaslos/tlsh"
	"github.com/go-redis/redis/v8"
	"github.com/google/uuid"
	"github.com/jhillyerd/enmime"
)

// --- Mailuminati engine configuration ---
const (
	EngineVersion   = "0.4.0"
	FragKeyPrefix   = "mi_f:"
	LocalFragPrefix = "lg_f:"
	MetaNodeID      = "mi_meta:id"
	MetaVer         = "mi_meta:v"
	DefaultOracle   = "https://oracle.mailuminati.com"
	MaxProcessSize  = 15 * 1024 * 1024 // 15 MB max
	MinVisualSize   = 50 * 1024        // Ignore small logos/trackers
)

var (
	ctx                 = context.Background()
	rdb                 *redis.Client
	oracleURL           string
	nodeID              string
	scanCount           int64
	partialMatchCount   int64
	spamConfirmedCount  int64
	cachedPositiveCount int64
	cachedNegativeCount int64
	localSpamCount      int64
)

type AnalysisResult struct {
	Action         string `json:"action"`
	Label          string `json:"label,omitempty"`
	ProximityMatch bool   `json:"proximity_match"`
	Distance       int    `json:"distance,omitempty"`
}

type SyncResponse struct {
	NewSeq int      `json:"new_seq"`
	Action string   `json:"action"`
	Ops    []SyncOp `json:"ops"`
}

type SyncOp struct {
	Action string   `json:"action"`
	Bands  []string `json:"bands"`
}

type ScanResult struct {
	Hashes    []string `json:"hashes"`
	Timestamp int64    `json:"timestamp"`
}

func main() {
	// Configuration
	oracleURL = getEnv("ORACLE_URL", DefaultOracle)

	redisHost := getEnv("REDIS_HOST", "localhost")
	redisPort := getEnv("REDIS_PORT", "6379")
	redisAddr := fmt.Sprintf("%s:%s", redisHost, redisPort)

	rdb = redis.NewClient(&redis.Options{
		Addr: redisAddr,
	})

	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Fatalf("[Mailuminati] Critical Redis error: %v", err)
	}

	nodeID = initNode()
	log.Printf("[Mailuminati] Engine %s started. Node: %s", EngineVersion, nodeID)

	// Workers
	go syncWorker()
	go statsWorker()

	// Endpoints
	http.HandleFunc("/analyze", analyzeHandler)
	http.HandleFunc("/report", logRequestHandler(reportHandler))
	http.HandleFunc("/status", logRequestHandler(statusHandler))

	log.Printf("[Mailuminati] MTA bridge ready on :1133")
	log.Fatal(http.ListenAndServe(":1133", nil))
}

// --- Handlers ---

func analyzeHandler(w http.ResponseWriter, r *http.Request) {
	atomic.AddInt64(&scanCount, 1)

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

	// 1. Analyze text body
	combinedBody := normalizeEmailBody(env.Text, env.HTML)
	if len(combinedBody) > 100 {
		if sig, err := computeLocalTLSH(combinedBody); err == nil {
			signatures = append(signatures, sig)
		} else {
			log.Printf("[Mailuminati] Failed to compute TLSH for body: %v", err)
		}
	}

	// 2. Analyze significant attachments
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
				goto endAnalysis // Final verdict; stop everything
			}
		}

		bands := extractBands_6_3(sig)
		var pipe redis.Pipeliner

		// Declare here to avoid "goto jumps over declaration"
		var matchCount int
		var oracleCmds []*redis.IntCmd

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
				pipe.Expire(ctx, key, 15*24*time.Hour)
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
							log.Printf("[Mailuminati] Local spam detected! Message-ID: %s | Subject: %s | Signature: %s | Match: %s", messageID, subject, sig, hash)
							finalResult = AnalysisResult{Action: "spam", Label: "local_spam", ProximityMatch: true, Distance: dist}
							atomic.AddInt64(&localSpamCount, 1)
							isLocalSpam = true
							break // A single match is enough
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
				break // Final verdict; stop everything
			} else {
				log.Printf("[Mailuminati] Oracle partial match. Message-ID: %s | Subject: %s | Signature: %s", messageID, subject, sig)
				finalResult.ProximityMatch = true
				atomic.AddInt64(&partialMatchCount, 1)
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
	key := "mi:msgid:" + sha1Hash

	val, err := rdb.Get(ctx, key).Result()
	if err == redis.Nil {
		http.Error(w, "No scan data found", http.StatusNotFound)
		return
	}

	var scanData ScanResult
	json.Unmarshal([]byte(val), &scanData)

	// --- Local learning ---
	if reqBody.ReportType == "spam" {
		log.Printf("[Mailuminati] Learning from spam report for Message-ID: %s", reqBody.MessageID)
		pipe := rdb.Pipeline()
		for _, hash := range scanData.Hashes {
			bands := extractBands_6_3(hash)
			for _, band := range bands {
				key := LocalFragPrefix + band
				pipe.SAdd(ctx, key, hash)
				pipe.Expire(ctx, key, 15*24*time.Hour)
			}
		}
		pipe.Exec(ctx)
	}
	// --- End local learning ---

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
	// We ignore includeLen parameter as the library doesn't support excluding it easily without forking.
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

// --- Helpers and Workers ---

func normalizeEmailBody(text, html string) string {
	body := text + "\n\n" + html
	body = strings.TrimSpace(body)

	reImgSrc := regexp.MustCompile(`(?i)<img([^>]*?)src="[^"]*"([^>]*?)>`)
	body = reImgSrc.ReplaceAllString(body, `<img$1src="imgurl"$2>`)

	reHex8 := regexp.MustCompile(`[0-9a-fA-F]{8,}`)
	body = reHex8.ReplaceAllString(body, "****")

	reDigit6 := regexp.MustCompile(`\d{6,}`)
	body = reDigit6.ReplaceAllString(body, "****")

	reStyleAttr := regexp.MustCompile(`(?i)\s*style\s*=\s*"[^"]*"`)
	body = reStyleAttr.ReplaceAllString(body, "")

	reTrackers := regexp.MustCompile(`(?i)([?&])(utm_[^=&]+|gclid|fbclid|mc_eid|mc_cid)=[^&\s]+`)
	body = reTrackers.ReplaceAllString(body, "$1")

	body = strings.ToLower(body)
	reSpaces := regexp.MustCompile(`[ \t]+`)
	body = reSpaces.ReplaceAllString(body, " ")
	reNewlines := regexp.MustCompile(`\r?\n{2,}`)
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
	rdb.Set(ctx, key, resultBytes, 7*24*time.Hour)
}

func callOracleDecision(sig string) AnalysisResult {
	cacheKey := "mi:oracle_cache:" + sig
	if cached, err := rdb.Get(ctx, cacheKey).Result(); err == nil {
		var res AnalysisResult
		if json.Unmarshal([]byte(cached), &res) == nil {
			if res.Action == "spam" {
				atomic.AddInt64(&cachedPositiveCount, 1)
			} else {
				atomic.AddInt64(&cachedNegativeCount, 1)
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
			cacheDuration = 1 * time.Hour
		}
		data, _ := json.Marshal(res.Result)
		rdb.Set(ctx, cacheKey, data, cacheDuration)
		return res.Result
	}

	return AnalysisResult{Action: "allow", ProximityMatch: true}
}

// Database sync worker
func syncWorker() {
	doSync()
	ticker := time.NewTicker(1 * time.Minute)
	for range ticker.C {
		doSync()
	}
}

func doSync() {
	currentSeq, _ := rdb.Get(ctx, MetaVer).Int()
	payload, _ := json.Marshal(map[string]interface{}{"node_id": nodeID, "current_seq": currentSeq})

	resp, err := http.Post(oracleURL+"/sync", "application/json", bytes.NewBuffer(payload))
	if err != nil || resp.StatusCode != http.StatusOK {
		return
	}
	defer resp.Body.Close()

	var syncData SyncResponse
	if err := json.NewDecoder(resp.Body).Decode(&syncData); err != nil {
		return
	}

	if syncData.Action == "UPDATE_DELTA" {
		pipe := rdb.Pipeline()
		for _, op := range syncData.Ops {
			for _, band := range op.Bands {
				if op.Action == "add" {
					pipe.Set(ctx, FragKeyPrefix+band, "1", 0)
				} else if op.Action == "del" {
					pipe.Del(ctx, FragKeyPrefix+band)
				}
			}
		}
		pipe.Exec(ctx)
		rdb.Set(ctx, MetaVer, syncData.NewSeq, 0)
	} else if syncData.Action == "RESET_DB" {
		iter := rdb.Scan(ctx, 0, FragKeyPrefix+"*", 0).Iterator()
		for iter.Next(ctx) {
			rdb.Del(ctx, iter.Val())
		}
		rdb.Set(ctx, MetaVer, 0, 0)
	}
}

// Statistics reporting worker
func statsWorker() {
	ticker := time.NewTicker(10 * time.Minute)
	for range ticker.C {
		scanned := atomic.SwapInt64(&scanCount, 0)
		partials := atomic.SwapInt64(&partialMatchCount, 0)
		spams := atomic.SwapInt64(&spamConfirmedCount, 0)
		cachedPositives := atomic.SwapInt64(&cachedPositiveCount, 0)
		cachedNegatives := atomic.SwapInt64(&cachedNegativeCount, 0)
		localSpams := atomic.SwapInt64(&localSpamCount, 0)

		if scanned == 0 && partials == 0 && spams == 0 && cachedPositives == 0 && cachedNegatives == 0 && localSpams == 0 {
			continue
		}

		payload, _ := json.Marshal(map[string]interface{}{
			"node_id":               nodeID,
			"scanned_count":         scanned,
			"partial_match_count":   partials,
			"spam_confirmed_count":  spams,
			"cached_positive_count": cachedPositives,
			"cached_negative_count": cachedNegatives,
			"local_spam_count":      localSpams,
		})

		resp, err := http.Post(oracleURL+"/stats", "application/json", bytes.NewBuffer(payload))
		if err != nil || resp.StatusCode > 299 {
			atomic.AddInt64(&scanCount, scanned)
			atomic.AddInt64(&partialMatchCount, partials)
			atomic.AddInt64(&spamConfirmedCount, spams)
			atomic.AddInt64(&cachedPositiveCount, cachedPositives)
			atomic.AddInt64(&cachedNegativeCount, cachedNegatives)
			atomic.AddInt64(&localSpamCount, localSpams)
		}
	}
}

func firstInt(s string) *int {
	sc := bufio.NewScanner(strings.NewReader(s))
	sc.Split(bufio.ScanWords)
	for sc.Scan() {
		if n, err := strconv.Atoi(sc.Text()); err == nil {
			return &n
		}
	}
	return nil
}

func initNode() string {
	id, _ := rdb.Get(ctx, MetaNodeID).Result()
	if id == "" {
		id = uuid.New().String()
		rdb.Set(ctx, MetaNodeID, id, 0)
		rdb.Set(ctx, MetaVer, 0, 0)
	}
	return id
}

func getEnv(k, f string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return f
}

func logRequestHandler(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		log.Printf("[Mailuminati] Request: %s %s", r.Method, r.URL.Path)
		next.ServeHTTP(w, r)
	}
}
