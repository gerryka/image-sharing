// Package server implementiert die HTTP-/WebSocket-API aus docs/PROTOCOL.md.
package server

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"

	"imgshare/internal/store"
)

const (
	tokenLen       = 32
	minCiphertext  = 12 + 16 // Nonce + GCM-Tag
	defaultLimit   = 100
	maxLimit       = 500
	maxWSPerRoom   = 8
	authFailMax    = 10
	authFailWindow = time.Minute
	uploadTimeout  = 10 * time.Minute

	// InviteHeader trägt den Server-Zugangscode, der zum Anlegen neuer Räume nötig ist.
	InviteHeader = "X-Invite-Code"
)

var (
	roomRe = regexp.MustCompile(`^[0-9a-f]{32}$`)
	uuidRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
)

type Config struct {
	MaxBlobBytes    int64
	MaxMessageBytes int64
	// RoomCreateSecret: Zugangscode für neue Räume. Leer = keine neuen Räume.
	RoomCreateSecret string
	MaxRooms         int64 // Obergrenze für Räume insgesamt
	RoomQuotaBytes   int64 // Speicher pro Raum (Blobs + Nachrichten)
	MinFreeBytes     int64 // so viel muss auf DATA_DIR frei bleiben
	MaxWSTotal       int   // WebSocket-Verbindungen insgesamt
	MaxListBytes     int64 // Ciphertext-Bytes pro GET-messages-Antwort
}

func (c *Config) applyDefaults() {
	def := func(v *int64, d int64) {
		if *v <= 0 {
			*v = d
		}
	}
	def(&c.MaxRooms, 100)
	def(&c.RoomQuotaBytes, 2<<30)
	def(&c.MinFreeBytes, 1<<30)
	def(&c.MaxListBytes, 8<<20)
	if c.MaxWSTotal <= 0 {
		c.MaxWSTotal = 200
	}
}

type Server struct {
	cfg        Config
	inviteHash [32]byte
	store      *store.Store
	hub        *hub
	limiter    *failLimiter
	upgrader   websocket.Upgrader
	mux        *http.ServeMux
	freeBytes  func(path string) (int64, error)
}

func New(cfg Config, st *store.Store) *Server {
	cfg.applyDefaults()
	s := &Server{
		cfg:        cfg,
		inviteHash: sha256.Sum256([]byte(cfg.RoomCreateSecret)),
		store:      st,
		hub:        newHub(),
		limiter:    newFailLimiter(authFailMax, authFailWindow),
		freeBytes:  freeBytes,
		upgrader: websocket.Upgrader{
			ReadBufferSize:  1024,
			WriteBufferSize: 4096,
		},
		mux: http.NewServeMux(),
	}
	s.mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		io.WriteString(w, "ok")
	})
	s.mux.HandleFunc("POST /v1/rooms/{room}/messages", s.auth(s.postMessage))
	s.mux.HandleFunc("GET /v1/rooms/{room}/messages", s.auth(s.getMessages))
	s.mux.HandleFunc("POST /v1/rooms/{room}/blobs", s.auth(s.postBlob))
	s.mux.HandleFunc("GET /v1/rooms/{room}/blobs/{blob}", s.auth(s.getBlob))
	s.mux.HandleFunc("GET /v1/rooms/{room}/ws", s.auth(s.ws))
	s.mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "not_found")
	})
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) { s.mux.ServeHTTP(w, r) }

// RunMaintenance räumt periodisch den Rate-Limiter auf, bis ctx endet.
func (s *Server) RunMaintenance(ctx context.Context) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.limiter.Cleanup()
		}
	}
}

// Shutdown schließt alle WebSocket-Verbindungen.
func (s *Server) Shutdown() { s.hub.closeAll() }

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		room := r.PathValue("room")
		if !roomRe.MatchString(room) {
			writeError(w, http.StatusBadRequest, "bad_request")
			return
		}
		ip := clientIP(r)
		// Gültige Tokens werden nie gesperrt (NAT); nur Fehlversuche zählen und werden gedrosselt.
		reject := func(status int, code string) {
			if s.limiter.Blocked(ip) {
				w.Header().Set("Retry-After", "60")
				writeError(w, http.StatusTooManyRequests, "rate_limited")
				return
			}
			s.limiter.Fail(ip)
			writeError(w, status, code)
		}

		token, ok := bearerToken(r)
		if !ok {
			reject(http.StatusUnauthorized, "unauthorized")
			return
		}
		sum := sha256.Sum256(token)
		stored, found, err := s.store.RoomTokenHash(r.Context(), room)
		if err != nil {
			internalError(w, "room lookup", err)
			return
		}
		if !found {
			if !s.inviteOK(r) {
				log.Printf("room create denied room=%s… ip=%s", room[:8], ip)
				reject(http.StatusForbidden, "invite_required")
				return
			}
			stored, err = s.store.CreateRoom(r.Context(), room, sum[:], s.cfg.MaxRooms)
			if errors.Is(err, store.ErrRoomLimit) {
				log.Printf("room limit reached (%d)", s.cfg.MaxRooms)
				writeError(w, http.StatusInsufficientStorage, "room_limit")
				return
			}
			if err != nil {
				internalError(w, "create room", err)
				return
			}
			log.Printf("room created room=%s… ip=%s", room[:8], ip)
		}
		if subtle.ConstantTimeCompare(stored, sum[:]) != 1 {
			log.Printf("auth failed room=%s… ip=%s", room[:8], ip)
			reject(http.StatusUnauthorized, "unauthorized")
			return
		}
		next(w, r)
	}
}

// inviteOK prüft den Zugangscode für neue Räume (zeitkonstant). Ohne
// konfiguriertes Secret können keine Räume angelegt werden.
func (s *Server) inviteOK(r *http.Request) bool {
	if s.cfg.RoomCreateSecret == "" {
		return false
	}
	got := sha256.Sum256([]byte(strings.TrimSpace(r.Header.Get(InviteHeader))))
	return subtle.ConstantTimeCompare(got[:], s.inviteHash[:]) == 1
}

// checkStorage prüft vor einem Schreibzugriff Raumquote und freien Plattenplatz.
// Schreibt bei Ablehnung die Antwort und liefert false.
func (s *Server) checkStorage(w http.ResponseWriter, r *http.Request, room string, incoming int64) bool {
	free, err := s.freeBytes(s.store.BlobDir())
	if err != nil {
		internalError(w, "statfs", err)
		return false
	}
	if free-incoming < s.cfg.MinFreeBytes {
		log.Printf("disk almost full: %d bytes free", free)
		writeError(w, http.StatusInsufficientStorage, "insufficient_storage")
		return false
	}
	used, err := s.store.RoomUsage(r.Context(), room)
	if err != nil {
		internalError(w, "room usage", err)
		return false
	}
	if used+incoming > s.cfg.RoomQuotaBytes {
		writeError(w, http.StatusInsufficientStorage, "quota_exceeded")
		return false
	}
	return true
}

func bearerToken(r *http.Request) ([]byte, bool) {
	h := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(h) <= len(prefix) || !strings.EqualFold(h[:len(prefix)], prefix) {
		return nil, false
	}
	tok, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(h[len(prefix):]))
	if err != nil || len(tok) != tokenLen {
		return nil, false
	}
	return tok, true
}

func (s *Server) postMessage(w http.ResponseWriter, r *http.Request) {
	room := r.PathValue("room")
	// Base64 bläht um 4/3 auf; etwas Reserve für das JSON drumherum.
	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxMessageBytes*4/3+1024)
	var req struct {
		Ciphertext []byte `json:"ciphertext"` // encoding/json dekodiert Standard-Base64
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeError(w, http.StatusRequestEntityTooLarge, "too_large")
			return
		}
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	if int64(len(req.Ciphertext)) > s.cfg.MaxMessageBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "too_large")
		return
	}
	if len(req.Ciphertext) < minCiphertext {
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	if !s.checkStorage(w, r, room, int64(len(req.Ciphertext))) {
		return
	}
	m, err := s.store.AddMessage(r.Context(), room, req.Ciphertext)
	if err != nil {
		internalError(w, "add message", err)
		return
	}
	s.hub.broadcast(room, messageEvent{Type: "message", ID: m.ID, ServerTS: m.ServerTS, Ciphertext: m.Ciphertext})
	writeJSON(w, http.StatusCreated, map[string]any{"id": m.ID, "server_ts": m.ServerTS})
}

func (s *Server) getMessages(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	after, ok1 := parseInt(q.Get("after"), 0)
	before, ok2 := parseInt(q.Get("before"), 0)
	limit, ok3 := parseInt(q.Get("limit"), defaultLimit)
	if !ok1 || !ok2 || !ok3 || after < 0 || before < 0 || limit < 1 {
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	if limit > maxLimit {
		limit = maxLimit
	}
	msgs, hasMore, err := s.store.ListMessages(r.Context(), r.PathValue("room"), after, before, int(limit), s.cfg.MaxListBytes)
	if err != nil {
		internalError(w, "list messages", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": msgs, "has_more": hasMore})
}

func parseInt(s string, def int64) (int64, bool) {
	if s == "" {
		return def, true
	}
	v, err := strconv.ParseInt(s, 10, 64)
	return v, err == nil
}

func (s *Server) postBlob(w http.ResponseWriter, r *http.Request) {
	room := r.PathValue("room")
	if r.ContentLength > s.cfg.MaxBlobBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "too_large")
		return
	}
	incoming := r.ContentLength
	if incoming <= 0 {
		incoming = s.cfg.MaxBlobBytes // unbekannte Länge: vom Maximum ausgehen
	}
	if !s.checkStorage(w, r, room, incoming) {
		return
	}
	// Nur Uploads dürfen länger als der globale ReadTimeout dauern.
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(uploadTimeout))
	id, size, err := s.store.PutBlob(r.Context(), room, r.Body, s.cfg.MaxBlobBytes)
	switch {
	case errors.Is(err, store.ErrTooLarge):
		writeError(w, http.StatusRequestEntityTooLarge, "too_large")
		return
	case err != nil:
		internalError(w, "put blob", err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"blob_id": id, "size": size})
}

func (s *Server) getBlob(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("blob")
	if !uuidRe.MatchString(id) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	f, size, err := s.store.OpenBlob(r.Context(), r.PathValue("room"), id)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
		return
	case err != nil:
		internalError(w, "open blob", err)
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	w.WriteHeader(http.StatusOK)
	io.Copy(w, f)
}

func (s *Server) ws(w http.ResponseWriter, r *http.Request) {
	room := r.PathValue("room")
	if s.hub.count(room) >= maxWSPerRoom || s.hub.total() >= s.cfg.MaxWSTotal {
		writeError(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return // Upgrader hat bereits geantwortet
	}
	c := &client{conn: conn, send: make(chan any, sendBuffer)}
	if !s.hub.add(room, c, maxWSPerRoom, s.cfg.MaxWSTotal) {
		conn.WriteControl(websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseTryAgainLater, "room full"),
			time.Now().Add(writeWait))
		conn.Close()
		return
	}
	go c.writeLoop()
	c.readLoop()
	s.hub.remove(room, c)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, map[string]string{"error": code})
}

func internalError(w http.ResponseWriter, what string, err error) {
	log.Printf("internal error (%s): %v", what, err)
	writeError(w, http.StatusInternalServerError, "internal")
}
