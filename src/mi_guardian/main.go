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
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
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

	// Initialize Logger
	initLogger()

	// Initial configuration load
	if err := loadConfigFile(*configPath); err != nil {
		logger.Warn("Config file error (using defaults/env)", "error", err)
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
			logger.Info("Received SIGHUP, reloading configuration...")
			if err := loadConfigFile(*configPath); err != nil {
				logger.Error("Error reloading config", "error", err)
			}
			refreshLogicConfig()
			logger.Info("Configuration reloaded",
				"spam_weight", atomic.LoadInt64(&spamWeight),
				"ham_weight", atomic.LoadInt64(&hamWeight),
				"threshold", atomic.LoadInt64(&localSpamThreshold),
				"retention", localRetentionDuration)
		}
	}()

	rdb = redis.NewClient(&redis.Options{
		Addr: redisAddr,
	})

	if err := rdb.Ping(ctx).Err(); err != nil {
		logger.Error("Critical Redis error", "error", err)
		os.Exit(1)
	}

	nodeID = initNode()
	logger.Info("Engine started", "version", EngineVersion, "node_id", nodeID)

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
	logger.Info("MTA bridge ready", "address", bindAddr, "port", port)
	if err := http.ListenAndServe(bindAddr+":"+port, nil); err != nil {
		logger.Error("Server failed", "error", err)
		os.Exit(1)
	}
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

	// Load spam threshold from env/config (default 1)
	thresholdStr := getEnv("SPAM_THRESHOLD", "1")
	var threshold int64 = 1
	if th, err := strconv.ParseInt(thresholdStr, 10, 64); err == nil {
		threshold = th
	}
	// Safety: threshold must be at least 1
	if threshold < 1 {
		threshold = 1
	}
	atomic.StoreInt64(&localSpamThreshold, threshold)

	// Load retention duration from env/config
	retentionStr := getEnv("LOCAL_RETENTION_DAYS", strconv.Itoa(DefaultLocalRetention))
	if days, err := strconv.Atoi(retentionStr); err == nil && days > 0 {
		localRetentionDuration = time.Duration(days) * 24 * time.Hour
	} else {
		localRetentionDuration = time.Duration(DefaultLocalRetention) * 24 * time.Hour
	}

	// Load Image Analysis config
	imgAnalysisStr := getEnv("MI_ENABLE_IMAGE_ANALYSIS", "true")
	enableImageAnalysis = strings.ToLower(imgAnalysisStr) == "true"
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
