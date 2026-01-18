package main

import (
	"bufio"
	"os"
	"strconv"
	"strings"
)

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
	if v := os.Getenv(k); v != "" {
		return v
	}
	return f
}
