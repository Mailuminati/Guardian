package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"sync/atomic"
	"time"
)

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
	payload, _ := json.Marshal(map[string]interface{}{
		"node_id":     nodeID,
		"current_seq": currentSeq,
		"version":     EngineVersion,
	})

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
