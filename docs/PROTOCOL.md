# Bildsharing – Protokoll & Server-Spezifikation (v1)

Dieses Dokument ist die gemeinsame Grundlage für den **Server** (Go, gebaut am Mac,
läuft per docker-compose auf Debian 12) und den **Windows-Client** (.NET 8 / WPF).
Der Server ist absichtlich "dumm": er speichert und verteilt nur verschlüsselte
Bytes. Alle Kryptografie passiert im Client.

## 1. Betrieb

| Punkt | Festlegung |
|---|---|
| Adresse | `https://server.example.com:<PORT>` |
| Port | fixer High-Port, konfigurierbar über `LISTEN_ADDR` (Vorschlag `:47000`, max. 65535) |
| TLS | direkt im Go-Server, kein Reverse Proxy. Zertifikat + Key liegen am Host und werden read-only gemountet |
| Zert-Erneuerung | Server lädt Zertifikat bei Änderung neu (`tls.Config.GetCertificate`, mtime prüfen, z. B. alle 60 s) – kein Neustart nach Let's-Encrypt-Renewal nötig |
| Persistenz | `/data` als Volume: `/data/db.sqlite` + `/data/blobs/<room>/<blob_id>` |
| SQLite | `modernc.org/sqlite` (pure Go, kein CGO → Cross-Build am Mac für linux/amd64 problemlos) |

### Umgebungsvariablen

| Variable | Default | Bedeutung |
|---|---|---|
| `LISTEN_ADDR` | `:47000` | Listen-Adresse |
| `TLS_CERT` | `/certs/fullchain.pem` | Zertifikatskette |
| `TLS_KEY` | `/certs/privkey.pem` | privater Schlüssel |
| `DATA_DIR` | `/data` | DB + Blobs |
| `MAX_BLOB_BYTES` | `26214400` (25 MB) | max. Größe eines verschlüsselten Bildes |
| `MAX_MESSAGE_BYTES` | `65536` | max. Größe einer verschlüsselten Nachricht |

### docker-compose (Skizze)

```yaml
services:
  imgshare:
    build: .
    restart: unless-stopped
    ports:
      - "47000:47000"
    environment:
      LISTEN_ADDR: ":47000"
      TLS_CERT: /certs/live/server.example.com/fullchain.pem
      TLS_KEY: /certs/live/server.example.com/privkey.pem
    volumes:
      - ./data:/data
      # Let's Encrypt: ganzes Verzeichnis mounten, weil live/ Symlinks nach archive/ enthält
      - /etc/letsencrypt:/certs:ro
```

Der Container-User muss den Private Key lesen dürfen (ggf. als root laufen oder
Gruppenrechte am Host anpassen). Dockerfile: Multi-Stage, `golang` → `gcr.io/distroless/static`.

## 2. Kryptografie (nur Client – zur Info für den Server)

- **Root-Key `K`**: 32 Zufallsbytes, pro Chat, preshared. Anzeige als Base32
  (RFC 4648, ohne Padding) in 4er-Gruppen, z. B. `K7QF-2MXA-…`.
- Ableitung per **HKDF-SHA256**, Salt = `"imgshare-v1"`:
  - `enc_key  = HKDF(K, info="enc",    32 Bytes)` → AES-256-GCM
  - `room_id  = hex(HKDF(K, info="room", 16 Bytes))` → 32 Hex-Zeichen, kleingeschrieben
  - `token    = HKDF(K, info="auth",   32 Bytes)` → Zugriffstoken
  - `safety   = HKDF(K, info="safety",  8 Bytes)` → 12-stelliger Sicherheitscode
- Jede Nachricht und jedes Bild: AES-256-GCM, 12-Byte-Zufallsnonce,
  Format `nonce || ciphertext || tag`. AAD = `room_id` (ASCII).
- Der Klartext einer Nachricht ist JSON und enthält Absender, Typ, Text bzw.
  Bild-Metadaten (Dateiname, MIME, Größe, `blob_id`). **Der Server sieht davon nichts.**

**Was der Server sieht:** `room_id`, Zeitstempel, Größen, IP-Adressen. Sonst nichts.

## 3. Authentifizierung

Jeder Request trägt `Authorization: Bearer <base64url(token)>` (ohne Padding).

- Der Server speichert pro Raum nur `sha256(token)`.
- **Anlegen nur mit Zugangscode:** Existiert `room_id` noch nicht, legt der Server
  den Raum mit diesem Token-Hash nur an, wenn der Request zusätzlich
  `X-Invite-Code: <ROOM_CREATE_SECRET>` trägt (zeitkonstanter Vergleich).
  Sonst `403 invite_required` – und es wird nichts gespeichert. Ist
  `ROOM_CREATE_SECRET` nicht gesetzt, können keine neuen Räume entstehen.
  Bestehende Räume brauchen den Code nicht (zweiter Teilnehmer).
- Höchstens `MAX_ROOMS` Räume, sonst `507 room_limit`.
- Danach: Hash-Vergleich mit `subtle.ConstantTimeCompare`, sonst `401`.
- `room_id` muss `^[0-9a-f]{32}$` entsprechen, sonst `400`.
- Rate-Limit pro IP nur für Fehlversuche (10/min): danach `429` für weitere
  Fehlversuche. Gültige Tokens werden nie gesperrt (NAT-tauglich).

### Ressourcen-Limits

| Variable | Default | Wirkung |
|---|---|---|
| `ROOM_QUOTA_BYTES` | 2 GiB | Blobs + Nachrichten pro Raum, sonst `507 quota_exceeded` |
| `MIN_FREE_BYTES` | 1 GiB | freier Platz auf `DATA_DIR`, sonst `507 insufficient_storage` |
| `MAX_CONNS` / `MAX_CONNS_PER_IP` | 256 / 32 | TCP-Verbindungen (vor TLS) |
| `MAX_WS_TOTAL` | 200 | WebSockets insgesamt (pro Raum max. 8) |
| `MAX_LIST_BYTES` | 8 MiB | Ciphertext pro `GET …/messages`-Antwort (mind. 1 Nachricht; Rest über `has_more`) |

`ReadTimeout` ist 60 s; nur Blob-Uploads dürfen bis zu 10 min dauern.

## 4. HTTP-API

Basis: `/v1/rooms/{room_id}`. Antworten sind JSON, Binärdaten Base64 (Standard, mit Padding).

### `POST /v1/rooms/{room}/messages`
Request: `{"ciphertext": "<base64>"}`
Response `201`: `{"id": 42, "server_ts": "2026-11-07T09:14:03Z"}`
Danach Push an **alle** WebSocket-Verbindungen dieses Raums (auch an den Absender –
der Client dedupliziert über `id`). `id` ist global oder pro Raum streng
aufsteigend. `server_ts` ist RFC 3339 in UTC.

### `GET /v1/rooms/{room}/messages?after=<id>&limit=<n>`
`after` default 0, `limit` default 100, max 500. Aufsteigend nach `id`.
Response `200`: `{"messages": [{"id": 42, "server_ts": "…", "ciphertext": "<base64>"}], "has_more": false}`

Für "ältere Nachrichten nachladen" zusätzlich `before=<id>`: liefert die
**neuesten** `limit` Nachrichten mit `id < before` (exklusiv), aufsteigend sortiert;
`has_more` = es gibt noch ältere. **Wichtig:** Der Client lädt beim Start den
aktuellen Verlauf mit `before=9223372036854775807` (int64 max) – das muss
funktionieren. Sind `after` und `before` beide gesetzt, gewinnt `before`.

### `POST /v1/rooms/{room}/blobs`
Body: rohe verschlüsselte Bytes, `Content-Type: application/octet-stream`.
Response `201`: `{"blob_id": "<uuid v4>", "size": 188416}`
`413` wenn größer als `MAX_BLOB_BYTES`.

### `GET /v1/rooms/{room}/blobs/{blob_id}`
Response `200`: rohe Bytes, `application/octet-stream`. `404` wenn unbekannt.

### `GET /v1/rooms/{room}/ws` (WebSocket)
Auth über denselben Header. Server → Client:

```json
{"type": "message", "id": 43, "server_ts": "…", "ciphertext": "<base64>"}
{"type": "presence", "online": 2}
```

- `presence` wird bei jedem Connect/Disconnect im Raum gesendet (Anzahl
  verbundener Clients → "online"-Anzeige).
- Server sendet alle 30 s Ping; Client antwortet mit Pong.
- Client → Server: keine Nachrichten nötig (Senden läuft über `POST`).
- Nach Reconnect holt der Client Verpasstes über `GET …/messages?after=<letzte id>`.

### `GET /healthz`
Ohne Auth, `200 ok`.

## 5. Datenbank

```sql
CREATE TABLE rooms (
  id          TEXT PRIMARY KEY,          -- room_id
  token_hash  BLOB NOT NULL,             -- sha256(token)
  created_at  TEXT NOT NULL
);
CREATE TABLE messages (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  room_id     TEXT NOT NULL REFERENCES rooms(id),
  server_ts   TEXT NOT NULL,
  ciphertext  BLOB NOT NULL
);
CREATE INDEX messages_room_id ON messages(room_id, id);
CREATE TABLE blobs (
  id          TEXT PRIMARY KEY,          -- uuid
  room_id     TEXT NOT NULL REFERENCES rooms(id),
  size        INTEGER NOT NULL,
  created_at  TEXT NOT NULL
);
```

WAL-Modus aktivieren. Blobs werden atomar geschrieben (Temp-Datei + rename).

## 6. Fehlerformat

`{"error": "<kurzer code>"}` mit passendem Status: `400 bad_request`,
`401 unauthorized`, `404 not_found`, `413 too_large`, `429 rate_limited`, `500 internal`.

## 7. Klartext-Format der Nachrichten (nur Client)

Vor dem Verschlüsseln ist jede Nachricht JSON:

```json
{"v":1,"kind":"text","sender":"<device-id>","sender_name":"Georg","sent_at":"…","text":"Hallo"}
{"v":1,"kind":"image","sender":"…","sender_name":"…","sent_at":"…",
 "image":{"blob_id":"<uuid>","mime":"image/png","filename":"x.png","size":123,"width":1920,"height":1080}}
{"v":1,"kind":"read","sender":"…","sender_name":"…","sent_at":"…","read_up_to":42}
```

`read` sind Lesebestätigungen; sie werden wie normale Nachrichten gespeichert,
aber nicht angezeigt. Bild-Blobs werden mit demselben `enc_key` verschlüsselt.

## 8. Referenz-Mock

`tools/MockServer` (ASP.NET, In-Memory, ohne TLS) implementiert diese Spezifikation
für lokale Client-Tests. `client/ImgShare.SelfTest` prüft einen Server Ende-zu-Ende:

```
dotnet run --project client/ImgShare.SelfTest -- https://server.example.com:47000
```

(Der Klartext-Check über `/debug/dump` läuft nur gegen localhost.)

## 9. Nicht im Umfang v1

Löschen/Ablauf von Nachrichten, mehr als zwei Teilnehmer pro Raum (technisch
ginge es, ist aber nicht vorgesehen), Push über Firewalls ohne WebSocket.
