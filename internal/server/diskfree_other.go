//go:build !unix

package server

import "math"

// freeBytes: auf Nicht-Unix-Systemen (lokale Entwicklung unter Windows) keine Prüfung.
func freeBytes(string) (int64, error) { return math.MaxInt64, nil }
