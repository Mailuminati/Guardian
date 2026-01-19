package main

import (
	"context"
	"sync"
	"time"

	"github.com/go-redis/redis/v8"
	"github.com/prometheus/client_golang/prometheus"
)

// --- Mailuminati engine configuration ---
const (
	EngineVersion         = "0.5.2"
	FragKeyPrefix         = "mi_f:"
	LocalFragPrefix       = "lg_f:"
	OracleCacheFragPrefix = "oc_f:"
	LocalScorePrefix      = "lg_s:"
	MetaNodeID            = "mi_meta:id"
	MetaVer               = "mi_meta:v"
	DefaultOracle         = "https://oracle.mailuminati.com"
	MaxProcessSize        = 15 * 1024 * 1024 // 15 MB max
	MinVisualSize         = 50 * 1024        // Ignore small logos/trackers (internal attachments)
	MinExternalImageSize  = 40 * 1024        // Ignore small external images (visual analysis)
	DefaultLocalRetention = 15               // Days to keep local learning data
)

var (
	ctx                    = context.Background()
	rdb                    *redis.Client
	oracleURL              string
	nodeID                 string
	scanCount              int64
	partialMatchCount      int64
	spamConfirmedCount     int64
	cachedPositiveCount    int64
	cachedNegativeCount    int64
	localSpamCount         int64
	spamWeight             int64
	hamWeight              int64
	localRetentionDuration time.Duration

	// Image Analysis
	enableImageAnalysis bool = false
	maxExternalImages   int  = 10

	// Config
	configMap   map[string]string = make(map[string]string)
	configMutex sync.RWMutex

	// Prometheus metrics
	promScanned = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "mailuminati_guardian_scanned_total",
		Help: "Total number of emails scanned",
	})
	promLocalMatch = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "mailuminati_guardian_local_match_total",
		Help: "Total number of emails matched locally",
	})
	promOracleMatch = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mailuminati_guardian_oracle_match_total",
		Help: "Total number of emails matched via oracle",
	}, []string{"type"})
	promCacheHits = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mailuminati_guardian_cache_hits_total",
		Help: "Total number of cache hits",
	}, []string{"result"})
)
