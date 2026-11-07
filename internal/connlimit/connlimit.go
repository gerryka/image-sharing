// Package connlimit begrenzt gleichzeitige TCP-Verbindungen insgesamt und pro
// Quell-IP – noch vor dem TLS-Handshake, damit langsame oder massenhafte
// Verbindungen (Slowloris, Verbindungsfluten) den Server nicht erschöpfen.
package connlimit

import (
	"net"
	"sync"
)

type Listener struct {
	net.Listener
	maxTotal int
	maxPerIP int

	mu    sync.Mutex
	total int
	perIP map[string]int
}

// New umhüllt l. Verbindungen über dem Limit werden sofort geschlossen.
func New(l net.Listener, maxTotal, maxPerIP int) *Listener {
	return &Listener{Listener: l, maxTotal: maxTotal, maxPerIP: maxPerIP, perIP: map[string]int{}}
}

func (l *Listener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		ip := hostOf(c.RemoteAddr())
		l.mu.Lock()
		ok := l.total < l.maxTotal && l.perIP[ip] < l.maxPerIP
		if ok {
			l.total++
			l.perIP[ip]++
		}
		l.mu.Unlock()
		if !ok {
			c.Close()
			continue
		}
		return &conn{Conn: c, release: func() { l.release(ip) }}, nil
	}
}

func (l *Listener) release(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.total--
	if l.perIP[ip]--; l.perIP[ip] <= 0 {
		delete(l.perIP, ip)
	}
}

// Counts liefert die aktuellen Zähler (für Tests).
func (l *Listener) Counts(ip string) (total, perIP int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.total, l.perIP[ip]
}

func hostOf(a net.Addr) string {
	host, _, err := net.SplitHostPort(a.String())
	if err != nil {
		return a.String()
	}
	return host
}

type conn struct {
	net.Conn
	once    sync.Once
	release func()
}

func (c *conn) Close() error {
	err := c.Conn.Close()
	c.once.Do(c.release)
	return err
}
