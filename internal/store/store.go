// Package store kapselt SQLite (Räume, Nachrichten, Blob-Metadaten) und das
// Dateisystem-Layout der Blobs unter DATA_DIR/blobs/<room>/<blob_id>.
package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

var (
	ErrNotFound  = errors.New("not found")
	ErrTooLarge  = errors.New("too large")
	ErrRoomLimit = errors.New("room limit reached")
)

const schema = `
CREATE TABLE IF NOT EXISTS rooms (
  id          TEXT PRIMARY KEY,
  token_hash  BLOB NOT NULL,
  created_at  TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  room_id     TEXT NOT NULL REFERENCES rooms(id),
  server_ts   TEXT NOT NULL,
  ciphertext  BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_room_id ON messages(room_id, id);
CREATE TABLE IF NOT EXISTS blobs (
  id          TEXT PRIMARY KEY,
  room_id     TEXT NOT NULL REFERENCES rooms(id),
  size        INTEGER NOT NULL,
  created_at  TEXT NOT NULL
);
`

// TimeFormat ist das Zeitformat für server_ts (RFC 3339, UTC, Sekunden).
const TimeFormat = "2006-01-02T15:04:05Z"

type Store struct {
	db      *sql.DB
	blobDir string
	now     func() time.Time
}

type Message struct {
	ID         int64  `json:"id"`
	ServerTS   string `json:"server_ts"`
	Ciphertext []byte `json:"ciphertext"`
}

func Open(dataDir string) (*Store, error) {
	blobDir := filepath.Join(dataDir, "blobs")
	if err := os.MkdirAll(blobDir, 0o750); err != nil {
		return nil, err
	}
	dsn := "file:" + filepath.Join(dataDir, "db.sqlite") +
		"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// Eine Verbindung genügt für zwei Teilnehmer pro Raum und vermeidet SQLITE_BUSY.
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("schema: %w", err)
	}
	return &Store{db: db, blobDir: blobDir, now: time.Now}, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) ts() string { return s.now().UTC().Format(TimeFormat) }

// RoomTokenHash liefert den gespeicherten Token-Hash eines Raums.
// found == false, wenn der Raum nicht existiert. Legt nie etwas an.
func (s *Store) RoomTokenHash(ctx context.Context, room string) (hash []byte, found bool, err error) {
	err = s.db.QueryRowContext(ctx, `SELECT token_hash FROM rooms WHERE id = ?`, room).Scan(&hash)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return hash, true, nil
}

// CreateRoom legt einen Raum an (Trust on first use) und liefert den danach
// gespeicherten Token-Hash – bei einem parallelen Anlegen den des Gewinners.
// ErrRoomLimit, wenn bereits maxRooms Räume existieren.
func (s *Store) CreateRoom(ctx context.Context, room string, tokenHash []byte, maxRooms int64) ([]byte, error) {
	var n int64
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM rooms`).Scan(&n); err != nil {
		return nil, err
	}
	if n >= maxRooms {
		return nil, ErrRoomLimit
	}
	if _, err := s.db.ExecContext(ctx,
		`INSERT OR IGNORE INTO rooms (id, token_hash, created_at) VALUES (?, ?, ?)`,
		room, tokenHash, s.ts()); err != nil {
		return nil, err
	}
	h, _, err := s.RoomTokenHash(ctx, room)
	return h, err
}

// RoomUsage liefert den belegten Speicher eines Raums in Bytes (Blobs + Nachrichten).
func (s *Store) RoomUsage(ctx context.Context, room string) (int64, error) {
	var blobs, msgs int64
	err := s.db.QueryRowContext(ctx,
		`SELECT COALESCE((SELECT SUM(size) FROM blobs WHERE room_id = ?), 0),
		        COALESCE((SELECT SUM(LENGTH(ciphertext)) FROM messages WHERE room_id = ?), 0)`,
		room, room).Scan(&blobs, &msgs)
	return blobs + msgs, err
}

// BlobDir ist das Verzeichnis der Blobs (für die Prüfung des freien Speichers).
func (s *Store) BlobDir() string { return s.blobDir }

func (s *Store) AddMessage(ctx context.Context, room string, ciphertext []byte) (Message, error) {
	ts := s.ts()
	res, err := s.db.ExecContext(ctx,
		`INSERT INTO messages (room_id, server_ts, ciphertext) VALUES (?, ?, ?)`,
		room, ts, ciphertext)
	if err != nil {
		return Message{}, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return Message{}, err
	}
	return Message{ID: id, ServerTS: ts, Ciphertext: ciphertext}, nil
}

// ListMessages liefert Nachrichten aufsteigend nach id.
// before == 0: die ersten `limit` Nachrichten mit id > after.
// before  > 0: die letzten `limit` Nachrichten mit after < id < before.
// hasMore zeigt an, ob in Leserichtung weitere Nachrichten existieren.
// maxBytes begrenzt die Summe der Ciphertexte einer Antwort (mindestens eine
// Nachricht wird immer geliefert); wird abgeschnitten, ist hasMore true.
func (s *Store) ListMessages(ctx context.Context, room string, after, before int64, limit int, maxBytes int64) ([]Message, bool, error) {
	var q string
	args := []any{room, after}
	if before > 0 {
		q = `SELECT id, server_ts, ciphertext FROM messages
		     WHERE room_id = ? AND id > ? AND id < ? ORDER BY id DESC LIMIT ?`
		args = append(args, before, limit+1)
	} else {
		q = `SELECT id, server_ts, ciphertext FROM messages
		     WHERE room_id = ? AND id > ? ORDER BY id ASC LIMIT ?`
		args = append(args, limit+1)
	}
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	msgs := make([]Message, 0, min(limit, 64))
	var total int64
	truncated := false
	for rows.Next() {
		var m Message
		if err := rows.Scan(&m.ID, &m.ServerTS, &m.Ciphertext); err != nil {
			return nil, false, err
		}
		if len(msgs) > 0 && total+int64(len(m.Ciphertext)) > maxBytes {
			truncated = true
			break
		}
		total += int64(len(m.Ciphertext))
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return nil, false, err
	}
	hasMore := truncated || len(msgs) > limit
	if len(msgs) > limit {
		msgs = msgs[:limit]
	}
	if before > 0 {
		for i, j := 0, len(msgs)-1; i < j; i, j = i+1, j-1 {
			msgs[i], msgs[j] = msgs[j], msgs[i]
		}
	}
	return msgs, hasMore, nil
}

// PutBlob schreibt r atomar (Temp-Datei + rename) und registriert den Blob.
// Liefert ErrTooLarge, wenn r mehr als maxBytes liefert.
func (s *Store) PutBlob(ctx context.Context, room string, r io.Reader, maxBytes int64) (string, int64, error) {
	id, err := newUUID()
	if err != nil {
		return "", 0, err
	}
	dir := filepath.Join(s.blobDir, room)
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return "", 0, err
	}
	tmp, err := os.CreateTemp(dir, ".upload-*")
	if err != nil {
		return "", 0, err
	}
	tmpName := tmp.Name()
	committed := false
	defer func() {
		if !committed {
			tmp.Close()
			os.Remove(tmpName)
		}
	}()

	n, err := io.Copy(tmp, io.LimitReader(r, maxBytes+1))
	if err != nil {
		return "", 0, err
	}
	if n > maxBytes {
		return "", 0, ErrTooLarge
	}
	if err := tmp.Sync(); err != nil {
		return "", 0, err
	}
	if err := tmp.Close(); err != nil {
		return "", 0, err
	}
	final := filepath.Join(dir, id)
	if err := os.Rename(tmpName, final); err != nil {
		return "", 0, err
	}
	committed = true
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO blobs (id, room_id, size, created_at) VALUES (?, ?, ?, ?)`,
		id, room, n, s.ts()); err != nil {
		os.Remove(final)
		return "", 0, err
	}
	return id, n, nil
}

// OpenBlob öffnet einen Blob des Raums. ErrNotFound, wenn er nicht existiert
// oder zu einem anderen Raum gehört.
func (s *Store) OpenBlob(ctx context.Context, room, id string) (*os.File, int64, error) {
	var size int64
	err := s.db.QueryRowContext(ctx,
		`SELECT size FROM blobs WHERE id = ? AND room_id = ?`, id, room).Scan(&size)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, 0, ErrNotFound
	}
	if err != nil {
		return nil, 0, err
	}
	f, err := os.Open(filepath.Join(s.blobDir, room, id))
	if errors.Is(err, os.ErrNotExist) {
		return nil, 0, ErrNotFound
	}
	if err != nil {
		return nil, 0, err
	}
	return f, size, nil
}

func newUUID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40 // Version 4
	b[8] = (b[8] & 0x3f) | 0x80 // Variante RFC 4122
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}
