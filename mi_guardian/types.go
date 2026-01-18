package main

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
