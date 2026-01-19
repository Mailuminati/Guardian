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
	"bufio"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"io"
	"log"
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

// fetchImageSizeAndHash checks cache or downloads image to get size (and data if needed)
// Returns: data (if downloaded), hash (if cached), size, fromCache, error
func fetchImageForAnalysis(url string) ([]byte, string, int, bool, error) {
	urlHash := sha1.Sum([]byte(url))
	cacheKey := "mi:img:" + hex.EncodeToString(urlHash[:])

	// 1. Check Redis Cache (Format: "SIZE|HASH")
	if cachedVal, err := rdb.Get(ctx, cacheKey).Result(); err == nil {
		parts := strings.SplitN(cachedVal, "|", 2)
		if len(parts) == 2 {
			if size, err := strconv.Atoi(parts[0]); err == nil {
				log.Printf("[Mailuminati-Img] Cache HIT for %s (Size: %d)", url, size)
				return nil, parts[1], size, true, nil
			}
		}
	}

	// 2. Fetch Image
	log.Printf("[Mailuminati-Img] Fetching %s...", url)
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		log.Printf("[Mailuminati-Img] Fetch error for %s: %v", url, err)
		return nil, "", 0, false, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		log.Printf("[Mailuminati-Img] HTTP error for %s: Status %d", url, resp.StatusCode)
		return nil, "", 0, false, fmt.Errorf("status %d", resp.StatusCode)
	}

	// 3. Size Limits Check
	data, err := io.ReadAll(io.LimitReader(resp.Body, 10*1024*1024))
	if err != nil {
		log.Printf("[Mailuminati-Img] Read error for %s: %v", url, err)
		return nil, "", 0, false, err
	}

	if len(data) < MinExternalImageSize {
		log.Printf("[Mailuminati-Img] Skipped %s: Size %d bytes (Min: %d)", url, len(data), MinExternalImageSize)
		return nil, "", len(data), false, fmt.Errorf("too small")
	}

	return data, "", len(data), false, nil
}

// computeAndCacheImageHash processes the chosen image
func computeAndCacheImageHash(url string, data []byte) (string, error) {
	// Compute TLSH
	sig, err := computeLocalTLSH(string(data))
	if err != nil {
		log.Printf("[Mailuminati-Img] TLSH error for %s: %v", url, err)
		return "", err
	}

	// Store in Redis (Format: "SIZE|HASH")
	val := fmt.Sprintf("%d|%s", len(data), sig)
	urlHash := sha1.Sum([]byte(url))
	cacheKey := "mi:img:" + hex.EncodeToString(urlHash[:])
	rdb.Set(ctx, cacheKey, val, 24*time.Hour)

	log.Printf("[Mailuminati-Img] Hashed & Cached %s | Size: %d | Hash: %s", url, len(data), sig)
	return sig, nil
}
