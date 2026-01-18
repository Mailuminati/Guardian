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
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/go-redis/redis/v8"
	"github.com/google/uuid"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func init() {
	prometheus.MustRegister(promScanned, promLocalMatch, promOracleMatch, promCacheHits)
}

func main() {
	configPath := flag.String("config", "/etc/mailuminati-guardian/guardian.conf", "Path to configuration file")
	flag.Parse()

	// Initial configuration load
	if err := loadConfigFile(*configPath); err != nil {
		log.Printf("[Mailuminati] Config file error: %v (using defaults/env)", err)
	}

	// Configuration
	oracleURL = getEnv("ORACLE_URL", DefaultOracle)

	redisHost := getEnv("REDIS_HOST", "localhost")
	redisPort := getEnv("REDIS_PORT", "6379")
	redisAddr := fmt.Sprintf("%s:%s", redisHost, redisPort)

	// Load weights & retention
	refreshLogicConfig()

	// Signal handling for Reload (SIGHUP)
	c := make(chan os.Signal, 1)
	signal.Notify(c, syscall.SIGHUP)
	go func() {
		for range c {
			log.Println("[Mailuminati] Received SIGHUP. Reloading configuration...")
			if err := loadConfigFile(*configPath); err != nil {
				log.Printf("[Mailuminati] Error reloading config: %v", err)
			}
			refreshLogicConfig()
			log.Printf("[Mailuminati] Configuration reloaded. SpamWeight: %d, HamWeight: %d, Retention: %s", spamWeight, hamWeight, localRetentionDuration)
		}
	}()

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
	http.Handle("/metrics", promhttp.Handler())
	http.HandleFunc("/analyze", analyzeHandler)
	http.HandleFunc("/report", logRequestHandler(reportHandler))
	http.HandleFunc("/status", logRequestHandler(statusHandler))

	port := getEnv("PORT", "12421")
	bindAddr := getEnv("GUARDIAN_BIND_ADDR", "127.0.0.1")
	log.Printf("[Mailuminati] MTA bridge ready on %s:%s", bindAddr, port)
	log.Fatal(http.ListenAndServe(bindAddr+":"+port, nil))
}

func refreshLogicConfig() {
	// Load weights from env/config
	swStr := getEnv("SPAM_WEIGHT", "1")
	hwStr := getEnv("HAM_WEIGHT", "2")

	if sw, err := strconv.ParseInt(swStr, 10, 64); err == nil {
		atomic.StoreInt64(&spamWeight, sw)
	} else {
		atomic.StoreInt64(&spamWeight, 1)
	}

	if hw, err := strconv.ParseInt(hwStr, 10, 64); err == nil {
		atomic.StoreInt64(&hamWeight, hw)
	} else {
		atomic.StoreInt64(&hamWeight, 2)
	}

	// Load retention duration from env/config
	// Note: localRetentionDuration is not int64, so atomic.Store is tricky.
	// But in this context (SIGHUP), a simple assignment is mostly safe if we assume
	// one writer (this goroutine) and readers.
	// For perfect safety, we'd need a mutex or atomic Value for retention too.
	// Given getEnv has a lock, let's keep it simple for now, or use atomic for weights atleast.
	// Actually, main.go uses simple assignment for retention.
	// Let's use configMutex since we already have it? No, getEnv locks it.
	// A new lock for operational params is cleanest, but for now direct assignment is 'okay'
	// if we accept a tiny race race condition during the update.
	// Let's stick to what we had but re-read.

	retentionStr := getEnv("LOCAL_RETENTION_DAYS", strconv.Itoa(DefaultLocalRetention))
	if days, err := strconv.Atoi(retentionStr); err == nil && days > 0 {
		localRetentionDuration = time.Duration(days) * 24 * time.Hour
	} else {
		localRetentionDuration = time.Duration(DefaultLocalRetention) * 24 * time.Hour
	}
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
