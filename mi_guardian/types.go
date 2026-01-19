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
