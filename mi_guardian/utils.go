package main

import (
	"bufio"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func loadConfigFile(path string) error {
	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // It's okay if file doesn't exist
		}
		return err
	}
	defer file.Close()

	configMutex.Lock()
	defer configMutex.Unlock()

	// Clear existing map to allow complete reload
	for k := range configMap {
		delete(configMap, k)
	}

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			key := strings.TrimSpace(parts[0])
			value := strings.TrimSpace(parts[1])
			// Handle quotes if present (basic)
			if len(value) >= 2 && strings.HasPrefix(value, "\"") && strings.HasSuffix(value, "\"") {
				value = value[1 : len(value)-1]
			}
			configMap[key] = value
		}
	}
	return scanner.Err()
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

func getEnv(k, f string) string {
	configMutex.RLock()
	if v, ok := configMap[k]; ok {
		configMutex.RUnlock()
		return v
	}
	configMutex.RUnlock()

	if v := os.Getenv(k); v != "" {
		return v
	}
	return f
}

// --- Image Analysis Helpers ---

// countWords removes HTML tags and counts words
func countWords(text string) int {
	fields := strings.Fields(text)
	return len(fields)
}

// shouldAnalyzeImages checks if content has little text (< 10 words)
func shouldAnalyzeImages(html string) bool {
	// Crude HTML strip
	reTag := regexp.MustCompile(`<[^>]*>`)
	text := reTag.ReplaceAllString(html, " ")
	return countWords(text) < 10
}

// extractImageURLs uses regex to find img src URLs (limit 10)
func extractImageURLs(html string) []string {
	reImgSrc := regexp.MustCompile(`(?i)<img[^>]+src=["'](https?://[^"']+)["'][^>]*>`)
	matches := reImgSrc.FindAllStringSubmatch(html, -1)

	urls := make([]string, 0, 10)
	seen := make(map[string]bool)

	for _, m := range matches {
		if len(m) > 1 {
			url := m[1]
			if !seen[url] {
				urls = append(urls, url)
				seen[url] = true
				if len(urls) >= maxExternalImages {
					break
				}
			}
		}
	}
	return urls
}

// fetchAndHashImage downloads image and computes TLSH with Redis caching
func fetchAndHashImage(url string) (string, error) {
	// 1. Check Redis Cache
	cacheKey := "mi:img:" + url
	if cachedHash, err := rdb.Get(ctx, cacheKey).Result(); err == nil {
		// Reset TTL on access? Optional. Let's keep it simple.
		return cachedHash, nil
	}

	// 2. Fetch Image
	client := &http.Client{
		Timeout: 5 * time.Second,
	}
	resp, err := client.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("status %d", resp.StatusCode)
	}

	// 3. Size Limits Check (Read first 50KB to check MIN size, max limit on reader)
	// We need MinVisualSize defined in globals.go
	data, err := io.ReadAll(io.LimitReader(resp.Body, 10*1024*1024)) // 10MB hard limit
	if err != nil {
		return "", err
	}

	if len(data) < MinVisualSize {
		return "", fmt.Errorf("too small: %d bytes", len(data))
	}

	// 4. Compute TLSH
	sig, err := computeLocalTLSH(string(data))
	if err != nil {
		return "", err
	}

	// 5. Store in Redis (24h TTL)
	rdb.Set(ctx, cacheKey, sig, 24*time.Hour)

	return sig, nil
}
