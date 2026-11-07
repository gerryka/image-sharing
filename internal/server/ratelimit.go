package server

import (
	"sync"
	"time"
)

// failLimiter zählt fehlgeschlagene Authentifizierungen pro IP in einem
// gleitenden Zeitfenster.
type failLimiter struct {
	mu     sync.Mutex
	max    int
	window time.Duration
	hits   map[string][]time.Time
	now    func() time.Time
}

func newFailLimiter(max int, window time.Duration) *failLimiter {
	return &failLimiter{max: max, window: window, hits: map[string][]time.Time{}, now: time.Now}
}

func (l *failLimiter) prune(ip string, now time.Time) []time.Time {
	h := l.hits[ip]
	i := 0
	for i < len(h) && now.Sub(h[i]) >= l.window {
		i++
	}
	h = h[i:]
	if len(h) == 0 {
		delete(l.hits, ip)
		return nil
	}
	l.hits[ip] = h
	return h
}

// Blocked meldet, ob ip das Limit an Fehlversuchen erreicht hat.
func (l *failLimiter) Blocked(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.prune(ip, l.now())) >= l.max
}

// Fail registriert einen Fehlversuch.
func (l *failLimiter) Fail(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	l.hits[ip] = append(l.prune(ip, now), now)
}

// Cleanup entfernt abgelaufene Einträge (periodisch aufrufen).
func (l *failLimiter) Cleanup() {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	for ip := range l.hits {
		l.prune(ip, now)
	}
}
