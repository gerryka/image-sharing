package server

import (
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	pingInterval = 30 * time.Second
	pongWait     = 75 * time.Second
	writeWait    = 10 * time.Second
	sendBuffer   = 64
)

// hub verwaltet die WebSocket-Verbindungen pro Raum.
type hub struct {
	mu    sync.Mutex
	rooms map[string]map[*client]struct{}
	n     int // Verbindungen insgesamt
}

type client struct {
	conn   *websocket.Conn
	send   chan any
	closed bool // geschützt durch hub.mu
}

func newHub() *hub { return &hub{rooms: map[string]map[*client]struct{}{}} }

func (h *hub) count(room string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.rooms[room])
}

func (h *hub) total() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.n
}

// add registriert c und meldet die neue Anzahl an alle im Raum.
func (h *hub) add(room string, c *client, maxPerRoom, maxTotal int) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.n >= maxTotal || len(h.rooms[room]) >= maxPerRoom {
		return false
	}
	m := h.rooms[room]
	if m == nil {
		m = map[*client]struct{}{}
		h.rooms[room] = m
	}
	m[c] = struct{}{}
	h.n++
	h.broadcastLocked(room, presenceEvent{Type: "presence", Online: len(m)})
	return true
}

func (h *hub) remove(room string, c *client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	m := h.rooms[room]
	if _, ok := m[c]; !ok {
		return
	}
	delete(m, c)
	h.n--
	c.close()
	if len(m) == 0 {
		delete(h.rooms, room)
		return
	}
	h.broadcastLocked(room, presenceEvent{Type: "presence", Online: len(m)})
}

func (h *hub) broadcast(room string, ev any) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.broadcastLocked(room, ev)
}

func (h *hub) broadcastLocked(room string, ev any) {
	for c := range h.rooms[room] {
		if c.closed {
			continue
		}
		select {
		case c.send <- ev:
		default:
			// Langsamer Client: Verbindung kappen, er holt nach dem Reconnect per GET nach.
			c.close()
		}
	}
}

func (h *hub) closeAll() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, m := range h.rooms {
		for c := range m {
			c.close()
		}
	}
}

// close schließt den Send-Channel genau einmal. Nur unter hub.mu aufrufen.
func (c *client) close() {
	if !c.closed {
		c.closed = true
		close(c.send)
	}
}

type presenceEvent struct {
	Type   string `json:"type"`
	Online int    `json:"online"`
}

type messageEvent struct {
	Type       string `json:"type"`
	ID         int64  `json:"id"`
	ServerTS   string `json:"server_ts"`
	Ciphertext []byte `json:"ciphertext"`
}

// writeLoop schreibt Events und Pings, bis send geschlossen wird.
func (c *client) writeLoop() {
	ticker := time.NewTicker(pingInterval)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()
	for {
		select {
		case ev, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				c.conn.WriteMessage(websocket.CloseMessage,
					websocket.FormatCloseMessage(websocket.CloseGoingAway, ""))
				return
			}
			if err := c.conn.WriteJSON(ev); err != nil {
				return
			}
		case <-ticker.C:
			if err := c.conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(writeWait)); err != nil {
				return
			}
		}
	}
}

// readLoop verwirft eingehende Daten und erkennt Verbindungsabbrüche.
func (c *client) readLoop() {
	c.conn.SetReadLimit(4096)
	c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		return c.conn.SetReadDeadline(time.Now().Add(pongWait))
	})
	for {
		if _, _, err := c.conn.NextReader(); err != nil {
			return
		}
	}
}
