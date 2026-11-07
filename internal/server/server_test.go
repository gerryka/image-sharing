package server

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"imgshare/internal/store"
)

const testInvite = "test-invite-code-1234"

type env struct {
	t    *testing.T
	ts   *httptest.Server
	srv  *Server
	room   string
	tok    string
	invite string
}

func newEnv(t *testing.T) *env {
	t.Helper()
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	srv := New(Config{MaxBlobBytes: 1024, MaxMessageBytes: 256, RoomCreateSecret: testInvite}, st)
	srv.freeBytes = func(string) (int64, error) { return 1 << 40, nil }
	ts := httptest.NewServer(srv)
	t.Cleanup(ts.Close)
	return &env{t: t, ts: ts, srv: srv, room: randHex(16), tok: randToken(), invite: testInvite}
}

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return fmt.Sprintf("%x", b)
}

func randToken() string {
	b := make([]byte, 32)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func randBytes(n int) []byte {
	b := make([]byte, n)
	rand.Read(b)
	return b
}

func (e *env) do(method, path, tok string, body io.Reader, ctype string) (*http.Response, []byte) {
	e.t.Helper()
	req, _ := http.NewRequest(method, e.ts.URL+path, body)
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	if e.invite != "" {
		req.Header.Set(InviteHeader, e.invite)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, b
}

func (e *env) postMsg(tok string, ct []byte) (*http.Response, []byte) {
	body, _ := json.Marshal(map[string][]byte{"ciphertext": ct})
	return e.do("POST", "/v1/rooms/"+e.room+"/messages", tok, bytes.NewReader(body), "application/json")
}

func wantStatus(t *testing.T, resp *http.Response, body []byte, status int, code string) {
	t.Helper()
	if resp.StatusCode != status {
		t.Fatalf("status = %d, want %d (body %s)", resp.StatusCode, status, body)
	}
	if code != "" {
		var e struct{ Error string }
		json.Unmarshal(body, &e)
		if e.Error != code {
			t.Fatalf("error = %q, want %q", e.Error, code)
		}
	}
}

func TestHealthz(t *testing.T) {
	e := newEnv(t)
	resp, body := e.do("GET", "/healthz", "", nil, "")
	if resp.StatusCode != 200 || string(body) != "ok" {
		t.Fatalf("got %d %q", resp.StatusCode, body)
	}
}

func TestAuthTOFU(t *testing.T) {
	e := newEnv(t)
	path := "/v1/rooms/" + e.room + "/messages"

	resp, body := e.do("GET", path, "", nil, "")
	wantStatus(t, resp, body, 401, "unauthorized")

	resp, body = e.do("GET", "/v1/rooms/NOTHEX/messages", e.tok, nil, "")
	wantStatus(t, resp, body, 400, "bad_request")

	resp, body = e.do("GET", path, "kurz", nil, "")
	wantStatus(t, resp, body, 401, "unauthorized")

	// Erster gültiger Request legt den Raum an.
	resp, body = e.do("GET", path, e.tok, nil, "")
	wantStatus(t, resp, body, 200, "")

	// Anderes Token für denselben Raum wird abgelehnt.
	resp, body = e.do("GET", path, randToken(), nil, "")
	wantStatus(t, resp, body, 401, "unauthorized")

	// Ursprüngliches Token funktioniert weiter.
	resp, body = e.do("GET", path, e.tok, nil, "")
	wantStatus(t, resp, body, 200, "")
}

func TestAuthRateLimit(t *testing.T) {
	e := newEnv(t)
	path := "/v1/rooms/" + e.room + "/messages"
	e.do("GET", path, e.tok, nil, "") // Raum anlegen
	for i := 0; i < authFailMax; i++ {
		resp, body := e.do("GET", path, randToken(), nil, "")
		wantStatus(t, resp, body, 401, "unauthorized")
	}
	// Ab jetzt werden Fehlversuche dieser IP gedrosselt …
	resp, body := e.do("GET", path, randToken(), nil, "")
	wantStatus(t, resp, body, 429, "rate_limited")
	// … ein gültiges Token (z. B. Kollege hinter demselben NAT) kommt aber weiter durch.
	resp, body = e.do("GET", path, e.tok, nil, "")
	wantStatus(t, resp, body, 200, "")

	// Nach Ablauf des Fensters werden Fehlversuche wieder normal beantwortet.
	e.srv.limiter.now = func() time.Time { return time.Now().Add(authFailWindow + time.Second) }
	resp, body = e.do("GET", path, randToken(), nil, "")
	wantStatus(t, resp, body, 401, "unauthorized")
}

func TestRoomCreationNeedsInvite(t *testing.T) {
	e := newEnv(t)
	path := "/v1/rooms/" + e.room + "/messages"

	// Ohne oder mit falschem Zugangscode wird kein Raum angelegt.
	e.invite = ""
	resp, body := e.do("GET", path, e.tok, nil, "")
	wantStatus(t, resp, body, 403, "invite_required")
	e.invite = "falsch-falsch-falsch"
	resp, body = e.do("GET", path, e.tok, nil, "")
	wantStatus(t, resp, body, 403, "invite_required")
	if _, found, _ := e.srv.store.RoomTokenHash(t.Context(), e.room); found {
		t.Fatal("room must not exist after denied requests")
	}

	// Mit Code anlegen; danach funktioniert der Raum auch ohne Code (zweiter Teilnehmer).
	e.invite = testInvite
	resp, body = e.do("GET", path, e.tok, nil, "")
	wantStatus(t, resp, body, 200, "")
	e.invite = ""
	resp, body = e.do("GET", path, e.tok, nil, "")
	wantStatus(t, resp, body, 200, "")

	// Fremdes Token für den bestehenden Raum: weiterhin 401, auch mit Code.
	e.invite = testInvite
	resp, body = e.do("GET", path, randToken(), nil, "")
	wantStatus(t, resp, body, 401, "unauthorized")
}

func TestRoomCreationDisabledWithoutSecret(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	srv := New(Config{MaxBlobBytes: 1024, MaxMessageBytes: 256}, st)
	ts := httptest.NewServer(srv)
	t.Cleanup(ts.Close)
	e := &env{t: t, ts: ts, srv: srv, room: randHex(16), tok: randToken(), invite: "irgendwas-irgendwas"}
	resp, body := e.do("GET", "/v1/rooms/"+e.room+"/messages", e.tok, nil, "")
	wantStatus(t, resp, body, 403, "invite_required")
}

func TestRoomLimit(t *testing.T) {
	e := newEnv(t)
	e.srv.cfg.MaxRooms = 2
	for i := 0; i < 2; i++ {
		other := &env{t: t, ts: e.ts, srv: e.srv, room: randHex(16), tok: randToken(), invite: testInvite}
		resp, body := other.do("GET", "/v1/rooms/"+other.room+"/messages", other.tok, nil, "")
		wantStatus(t, resp, body, 200, "")
	}
	resp, body := e.do("GET", "/v1/rooms/"+e.room+"/messages", e.tok, nil, "")
	wantStatus(t, resp, body, 507, "room_limit")
}

func TestQuotaAndDiskFull(t *testing.T) {
	e := newEnv(t)
	e.srv.cfg.RoomQuotaBytes = 1500
	blob := func(n int) (*http.Response, []byte) {
		return e.do("POST", "/v1/rooms/"+e.room+"/blobs", e.tok, bytes.NewReader(randBytes(n)), "application/octet-stream")
	}
	resp, body := blob(1000)
	wantStatus(t, resp, body, 201, "")
	resp, body = blob(600) // 1000 + 600 > 1500
	wantStatus(t, resp, body, 507, "quota_exceeded")
	resp, body = e.postMsg(e.tok, randBytes(200))
	wantStatus(t, resp, body, 201, "")
	resp, body = e.postMsg(e.tok, randBytes(250)) // 1200 + 250 ≤ 1500, aber …
	wantStatus(t, resp, body, 201, "")
	resp, body = e.postMsg(e.tok, randBytes(100)) // … 1450 + 100 > 1500
	wantStatus(t, resp, body, 507, "quota_exceeded")

	// Platte fast voll: jeder Schreibzugriff wird abgelehnt, Lesen geht weiter.
	e.srv.cfg.RoomQuotaBytes = 1 << 30
	e.srv.freeBytes = func(string) (int64, error) { return e.srv.cfg.MinFreeBytes + 10, nil }
	resp, body = e.postMsg(e.tok, randBytes(50))
	wantStatus(t, resp, body, 507, "insufficient_storage")
	resp, body = e.do("GET", "/v1/rooms/"+e.room+"/messages", e.tok, nil, "")
	wantStatus(t, resp, body, 200, "")
}

func TestListByteBudget(t *testing.T) {
	e := newEnv(t)
	e.srv.cfg.MaxListBytes = 500
	for i := 0; i < 5; i++ {
		resp, body := e.postMsg(e.tok, randBytes(200))
		wantStatus(t, resp, body, 201, "")
	}
	var l struct {
		Messages []store.Message `json:"messages"`
		HasMore  bool            `json:"has_more"`
	}
	resp, body := e.do("GET", "/v1/rooms/"+e.room+"/messages?before=9223372036854775807", e.tok, nil, "")
	wantStatus(t, resp, body, 200, "")
	json.Unmarshal(body, &l)
	if len(l.Messages) != 2 || l.Messages[0].ID != 4 || l.Messages[1].ID != 5 || !l.HasMore {
		t.Fatalf("budget(before): got %d msgs, has_more=%v", len(l.Messages), l.HasMore)
	}
	resp, body = e.do("GET", "/v1/rooms/"+e.room+"/messages?after=0", e.tok, nil, "")
	wantStatus(t, resp, body, 200, "")
	json.Unmarshal(body, &l)
	if len(l.Messages) != 2 || l.Messages[0].ID != 1 || !l.HasMore {
		t.Fatalf("budget(after): got %d msgs, has_more=%v", len(l.Messages), l.HasMore)
	}
	// Eine einzelne Nachricht über dem Budget wird trotzdem geliefert.
	e.srv.cfg.MaxListBytes = 10
	resp, body = e.do("GET", "/v1/rooms/"+e.room+"/messages?after=0", e.tok, nil, "")
	json.Unmarshal(body, &l)
	if len(l.Messages) != 1 || !l.HasMore {
		t.Fatalf("budget(min 1): got %d msgs", len(l.Messages))
	}
}

func TestMessagesRoundTripAndPaging(t *testing.T) {
	e := newEnv(t)
	var sent [][]byte
	for i := 0; i < 7; i++ {
		ct := randBytes(40 + i)
		resp, body := e.postMsg(e.tok, ct)
		wantStatus(t, resp, body, 201, "")
		var r struct {
			ID       int64  `json:"id"`
			ServerTS string `json:"server_ts"`
		}
		json.Unmarshal(body, &r)
		if r.ID != int64(i+1) || !strings.HasSuffix(r.ServerTS, "Z") {
			t.Fatalf("unexpected response %s", body)
		}
		sent = append(sent, ct)
	}

	type list struct {
		Messages []store.Message `json:"messages"`
		HasMore  bool            `json:"has_more"`
	}
	get := func(q string) list {
		resp, body := e.do("GET", "/v1/rooms/"+e.room+"/messages"+q, e.tok, nil, "")
		wantStatus(t, resp, body, 200, "")
		var l list
		if err := json.Unmarshal(body, &l); err != nil {
			t.Fatal(err)
		}
		return l
	}
	ids := func(l list) []int64 {
		var out []int64
		for _, m := range l.Messages {
			out = append(out, m.ID)
		}
		return out
	}

	l := get("")
	if len(l.Messages) != 7 || l.HasMore || !bytes.Equal(l.Messages[3].Ciphertext, sent[3]) {
		t.Fatalf("full list wrong: %+v", ids(l))
	}
	if l = get("?after=2&limit=3"); fmt.Sprint(ids(l)) != "[3 4 5]" || !l.HasMore {
		t.Fatalf("after paging: %v %v", ids(l), l.HasMore)
	}
	if l = get("?after=5&limit=3"); fmt.Sprint(ids(l)) != "[6 7]" || l.HasMore {
		t.Fatalf("after tail: %v %v", ids(l), l.HasMore)
	}
	if l = get("?before=6&limit=3"); fmt.Sprint(ids(l)) != "[3 4 5]" || !l.HasMore {
		t.Fatalf("before paging: %v %v", ids(l), l.HasMore)
	}
	if l = get("?before=3&limit=3"); fmt.Sprint(ids(l)) != "[1 2]" || l.HasMore {
		t.Fatalf("before head: %v %v", ids(l), l.HasMore)
	}

	resp, body := e.do("GET", "/v1/rooms/"+e.room+"/messages?limit=abc", e.tok, nil, "")
	wantStatus(t, resp, body, 400, "bad_request")

	// Andere Räume sehen nichts.
	other := &env{t: t, ts: e.ts, srv: e.srv, room: randHex(16), tok: randToken(), invite: testInvite}
	resp, body = other.do("GET", "/v1/rooms/"+other.room+"/messages", other.tok, nil, "")
	if !strings.Contains(string(body), `"messages":[]`) {
		t.Fatalf("other room not empty: %s", body)
	}
}

func TestMessageValidation(t *testing.T) {
	e := newEnv(t)
	resp, body := e.postMsg(e.tok, randBytes(257))
	wantStatus(t, resp, body, 413, "too_large")
	resp, body = e.postMsg(e.tok, randBytes(10))
	wantStatus(t, resp, body, 400, "bad_request")
	resp, body = e.do("POST", "/v1/rooms/"+e.room+"/messages", e.tok, strings.NewReader(`{"ciphertext":"!!"}`), "application/json")
	wantStatus(t, resp, body, 400, "bad_request")
	resp, body = e.do("POST", "/v1/rooms/"+e.room+"/messages", e.tok, strings.NewReader(`{"ciphertext":"`+strings.Repeat("A", 5000)+`"}`), "application/json")
	wantStatus(t, resp, body, 413, "too_large")
}

func TestBlobs(t *testing.T) {
	e := newEnv(t)
	data := randBytes(1000)
	resp, body := e.do("POST", "/v1/rooms/"+e.room+"/blobs", e.tok, bytes.NewReader(data), "application/octet-stream")
	wantStatus(t, resp, body, 201, "")
	var r struct {
		BlobID string `json:"blob_id"`
		Size   int64  `json:"size"`
	}
	json.Unmarshal(body, &r)
	if !uuidRe.MatchString(r.BlobID) || r.Size != 1000 {
		t.Fatalf("bad response %s", body)
	}

	resp, got := e.do("GET", "/v1/rooms/"+e.room+"/blobs/"+r.BlobID, e.tok, nil, "")
	if resp.StatusCode != 200 || !bytes.Equal(got, data) || resp.Header.Get("Content-Type") != "application/octet-stream" {
		t.Fatalf("download failed: %d len=%d", resp.StatusCode, len(got))
	}

	// Zu groß (mit und ohne Content-Length).
	resp, body = e.do("POST", "/v1/rooms/"+e.room+"/blobs", e.tok, bytes.NewReader(randBytes(1025)), "application/octet-stream")
	wantStatus(t, resp, body, 413, "too_large")
	resp, body = e.do("POST", "/v1/rooms/"+e.room+"/blobs", e.tok, io.MultiReader(bytes.NewReader(randBytes(2000))), "application/octet-stream")
	wantStatus(t, resp, body, 413, "too_large")

	resp, body = e.do("GET", "/v1/rooms/"+e.room+"/blobs/00000000-0000-4000-8000-000000000000", e.tok, nil, "")
	wantStatus(t, resp, body, 404, "not_found")
	resp, body = e.do("GET", "/v1/rooms/"+e.room+"/blobs/../../db.sqlite", e.tok, nil, "")
	if resp.StatusCode == 200 {
		t.Fatal("path traversal returned 200")
	}

	// Blob ist aus einem fremden Raum nicht abrufbar.
	other := &env{t: t, ts: e.ts, srv: e.srv, room: randHex(16), tok: randToken(), invite: testInvite}
	resp, body = other.do("GET", "/v1/rooms/"+other.room+"/blobs/"+r.BlobID, other.tok, nil, "")
	wantStatus(t, resp, body, 404, "not_found")
}

func (e *env) dialWS(tok string) (*websocket.Conn, *http.Response, error) {
	u := "ws" + strings.TrimPrefix(e.ts.URL, "http") + "/v1/rooms/" + e.room + "/ws"
	h := http.Header{}
	if tok != "" {
		h.Set("Authorization", "Bearer "+tok)
	}
	if e.invite != "" {
		h.Set(InviteHeader, e.invite)
	}
	return websocket.DefaultDialer.Dial(u, h)
}

type wsEvent struct {
	Type       string `json:"type"`
	Online     int    `json:"online"`
	ID         int64  `json:"id"`
	Ciphertext []byte `json:"ciphertext"`
}

func readEvent(t *testing.T, c *websocket.Conn) wsEvent {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	var ev wsEvent
	if err := c.ReadJSON(&ev); err != nil {
		t.Fatalf("read ws: %v", err)
	}
	return ev
}

func TestWebSocket(t *testing.T) {
	e := newEnv(t)

	if _, resp, err := e.dialWS(""); err == nil || resp.StatusCode != 401 {
		t.Fatalf("ws without token: err=%v", err)
	}

	a, _, err := e.dialWS(e.tok)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	if ev := readEvent(t, a); ev.Type != "presence" || ev.Online != 1 {
		t.Fatalf("a presence: %+v", ev)
	}

	b, _, err := e.dialWS(e.tok)
	if err != nil {
		t.Fatal(err)
	}
	if ev := readEvent(t, a); ev.Type != "presence" || ev.Online != 2 {
		t.Fatalf("a presence 2: %+v", ev)
	}
	if ev := readEvent(t, b); ev.Type != "presence" || ev.Online != 2 {
		t.Fatalf("b presence 2: %+v", ev)
	}

	if _, resp, err := e.dialWS(randToken()); err == nil || resp.StatusCode != 401 {
		t.Fatalf("wrong token ws: err=%v", err)
	}

	ct := randBytes(50)
	resp, body := e.postMsg(e.tok, ct)
	wantStatus(t, resp, body, 201, "")
	for _, c := range []*websocket.Conn{a, b} {
		ev := readEvent(t, c)
		if ev.Type != "message" || ev.ID != 1 || !bytes.Equal(ev.Ciphertext, ct) {
			t.Fatalf("message event: %+v", ev)
		}
	}

	b.Close()
	if ev := readEvent(t, a); ev.Type != "presence" || ev.Online != 1 {
		t.Fatalf("a presence after b left: %+v", ev)
	}
}
