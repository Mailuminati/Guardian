package main

import (
	"bufio"
	"os"
	"strconv"
	"strings"
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
	// Note: If you want to keep env vars that are NOT in the file, you might handle this differently,
	// but usually a reload implies "state of file + state of env".
	// Since we fall back to os.Getenv in getEnv(), simply clearing keys that might be removed is tricky
	// without knowing which came from where.
	// For now, we overwrite keys found in the file.
	// If we want to support removing a key via file, we'd need complex logic.
	// Simple approach: Just read file and update map.
	// Better approach for "Reload": We should probably clear the map first
	// so that removed lines in the file are no longer in the map.
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
