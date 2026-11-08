# ImgShare macOS Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Einen nativen macOS-Menüleisten-Client in Swift bauen, der byte-kompatibel zum Windows-Client mit dem unveränderten Go-Server chattet.

**Architecture:**
- Ein SwiftPM-Package `client-mac/` enthält die UI-freie Library `ImgShareCore`, ein Port von `client/ImgShare.Core`. Sie ist mit `swift test` testbar.
- Daneben liegt eine SwiftUI-App `ImgShareMac`. Ihr Xcode-Projekt wird per xcodegen aus `project.yml` erzeugt und bindet `ImgShareCore` als lokales Package ein.
- Zwei Go-Werkzeuge unter `tools/` liefern unabhängige Referenzdaten:
  - Testvektoren aus einer Go-Implementierung der Kryptografie
  - einen lokalen HTTP-Dev-Server mit dem echten Server-Code für Integrationstests

**Tech Stack:**
- Swift 6.4 (strict concurrency), SwiftUI, Observation
- Bibliotheken: CryptoKit, URLSession (inkl. `URLSessionWebSocketTask`), ImageIO, CoreImage (QR), Security (Keychain), UserNotifications, ServiceManagement
- xcodegen
- Go 1.26 für die Tools

**Spec:** `docs/superpowers/specs/2026-11-07-macos-client-design.md`

**Abweichung von der Spec (Verifikation):**
- Auf dem Mac gibt es kein .NET, und `ImgShare.SelfTest` braucht DPAPI, das nur unter Windows läuft.
- Ersatz für die Testvektoren: `tools/vectors` erzeugt sie mit Go-Standardkrypto.
- Ersatz für den Interop-Test: `tools/devserver` stellt den echten Server per HTTP bereit.
- Den Test Mac ↔ Windows macht der Nutzer am Ende manuell (Task 11).

## Global Constraints

**Plattform und Abhängigkeiten**
- Deployment-Target ist **macOS 27.0** (nur das aktuelle macOS). Swift-Language-Mode 6.
- Keine Fremdbibliotheken in Swift.
- Bundle-ID `at.mediatesystems.imgshare`. `LSUIElement = YES`, also kein Dock-Symbol.

**Sprache und Texte**
- Die UI-Texte sind Deutsch, wortgleich mit dem Windows-Client, wo es einen gibt (Fehlertexte aus `ErrorText.cs` / `ApiClient.cs`).

**Protokoll und Kryptografie** (unveränderlich, siehe `docs/PROTOCOL.md`, `client/ImgShare.Core/Crypto.cs`)
- HKDF-SHA256, Salt ASCII `imgshare-v1`. Info und Länge: `enc` 32, `room` 16 (Hex, Kleinbuchstaben), `auth` 32, `safety` 8.
- Sicherheitscode:
  - UInt64 **Little-Endian** aus den `safety`-Bytes, dann `% 1_000_000_000_000`, auf 12 Ziffern auffüllen.
  - Format `"ddd ddd · ddd ddd"`: zwischen den Gruppen Leerzeichen, Mittelpunkt U+00B7, Leerzeichen.
- AES-256-GCM: Nonce 12 B zufällig, Tag 16 B. Ausgabe ist `nonce‖ct‖tag`, die AAD ist room_id als ASCII. Daten unter 28 B werden abgelehnt.
- Token im Header als `Authorization: Bearer <base64url ohne Padding>`. Der Invite-Code steht in `X-Invite-Code` und wird nur mitgeschickt, wenn er nicht leer ist (getrimmt). User-Agent ist `ImgShare/1.0`.
- JSON-Binärdaten sind Standard-Base64 mit Padding.
- Der Klartext-Payload hat exakt die Feldnamen `v, kind, sender, sender_name, sent_at, text, image{blob_id,mime,filename,size,width,height}, read_up_to`.
- `blob_id` muss `^[A-Za-z0-9-]{1,64}$` entsprechen.
- Bilder sind nur PNG oder JPEG (Magic Bytes), mit max. 24 MiB = 25 165 824 B und max. 100 000 000 Pixeln.
- Server-URL: https ist Pflicht, http nur für Loopback (`localhost`, `127.0.0.1`, `::1`).

**Laufzeitverhalten**
- Reconnect-Backoff: Start bei 1 s, Verdopplung, höchstens 30 s, nach erfolgreicher Verbindung zurück auf 1 s.
- Erste Seite des Verlaufs: `before=9223372036854775807&limit=200`. Nachholen mit `after=<max>&limit=500`, bis `has_more` false ist. Ältere Nachrichten: `before=<min>&limit=100`.
- Online-Status gilt bei `presence.online >= 2`.
- Ein WebSocket-Frame darf höchstens 4 MiB groß sein, eine HTTP-Antwort höchstens 32 MiB. Der Request-Timeout beträgt 300 s.

**Speicherorte** (`$IMGSHARE_HOME` überschreibt beide wie unter Windows; die Config liegt dann direkt darin, der Cache in `<home>/cache`)
- Config: `~/Library/Application Support/ImgShare/config.json`
- Cache: `~/Library/Caches/ImgShare/<room>/<blob_id>`, Inhalt bleibt verschlüsselt.
- Keychain-Service `at.mediatesystems.imgshare`. Accounts: `<chatId>.key` und `<chatId>.invite`.

## Review Focus

1. **Zeitstempel aus .NET:** `sent_at` vom Windows-Client sieht aus wie `2026-11-07T10:00:00.1234567+00:00` (7 Nachkommastellen, Offset), `server_ts` wie `2026-11-07T10:00:00Z`. Beide Formate müssen dekodieren, sonst verwirft der Mac stillschweigend alle Windows-Nachrichten. Den Test dafür hat Task 3.
2. **Mac aus dem Ruhezustand / Server-Neustart:** Der WebSocket stirbt dabei oft lautlos. Die Session muss das per Ping erkennen und sich neu verbinden. Danach muss das Nachholen ohne Duplikate funktionieren. Den Test dafür hat Task 6 (Integrationstest).
3. **Müll vom Gegenüber oder Server:** Folgende Eingaben dürfen weder zum Absturz noch zu einer sichtbaren Nachricht führen:
   - nicht entschlüsselbarer Ciphertext
   - unbekanntes `kind`
   - leerer Text
   - unsichere `blob_id`
   - Bild mit mehr als 100 Mio. Pixeln
   - Dateiname mit `../` oder Bidi-Zeichen

   Die Tests dafür haben Task 3 und Task 5.
4. **Kaputte oder fehlende Konfiguration:** Ist `config.json` korrupt, wird sie als `.bak` gesichert und die App startet leer. Fehlt der Keychain-Eintrag, zeigt der Chat den Fehler, statt zu crashen. Den Test dafür hat Task 7.
5. **Zu langer Text oder zu großes Bild:** Der Server antwortet mit 413. Die App zeigt dann „Datei ist zu groß für den Server.“ und behält den Entwurf bzw. das Bild zum erneuten Senden. Die Tests dafür haben Task 4 (Fehlerabbildung) und Task 9 (Entwurf bleibt).

---

## File Structure

```
tools/vectors/main.go              Go: erzeugt client-mac/Tests/ImgShareCoreTests/Resources/vectors.json
tools/devserver/main.go            Go: echter Server per HTTP auf 127.0.0.1, Temp-Datenordner
client-mac/Package.swift
client-mac/Sources/ImgShareCore/
  ChatKeys.swift                   HKDF-Ableitung, Sicherheitscode, AES-GCM
  KeyFormat.swift                  Base32-Darstellung des Root-Keys
  Models.swift                     Wire- und Payload-Typen, JSON-Coder mit Datumsformat
  ImageFormat.swift                MIME-Erkennung, Grenzen, SafeFileName, Bildmaße, TIFF→PNG
  ApiClient.swift                  HTTP + WebSocket, ApiError, URL-Prüfung
  ErrorText.swift                  Fehler → deutscher Text
  ChatTransport.swift              Protokoll zwischen Session und ApiClient (für Fakes)
  ChatSession.swift                Verlauf, Reconnect, Senden, Lesebestätigung, Bilder
  Storage/AppConfig.swift          config.json (ChatEntry, AppConfig)
  Storage/KeychainStore.swift      Root-Key und Invite im Keychain
  Storage/BlobCache.swift          verschlüsselter Bild-Cache
  Presentation/DayLabel.swift      „Heute/Gestern/Datum“
  Presentation/NotificationBatcher.swift  Bündelung + 120-Zeichen-Vorschau
client-mac/Tests/ImgShareCoreTests/   ein Testfile pro Quelle, plus Resources/vectors.json
client-mac/project.yml             xcodegen-Spezifikation der App
client-mac/ImgShareMac/
  ImgShareMacApp.swift             @main, MenuBarExtra, Fenster-Szenen
  AppModel.swift                   hält AppConfig + alle ChatSessions, Ungelesen-Summe
  MenuBarContent.swift             Menüinhalt
  LoginItem.swift                  SMAppService-Wrapper
  Setup/SetupView.swift            Chat einrichten/bearbeiten
  Setup/QRCodeView.swift
  Chat/ChatView.swift, MessageRow.swift, ComposerView.swift, ChatViewModel.swift
  Chat/PasteboardImage.swift       Bild aus NSPasteboard / Drop / Datei lesen
  Viewer/ImageViewerView.swift
  Notifications.swift              UNUserNotificationCenter
  Info.plist, Assets.xcassets
.github/workflows/mac-client.yml
README.md                          Abschnitt „macOS client“
```

---

### Task 1: Package-Gerüst, Go-Testvektoren, ChatKeys

**Files:**
- Create: `tools/vectors/main.go`, `client-mac/Package.swift`, `client-mac/Sources/ImgShareCore/ChatKeys.swift`
- Create: `client-mac/Tests/ImgShareCoreTests/ChatKeysTests.swift`, `.../Resources/vectors.json` (generiert)
- Modify: `.gitignore`: `client-mac/.build/`, `client-mac/*.xcodeproj` (generiert), `client-mac/build/`

**Interfaces:**
- Produces:
  - `public struct ChatKeys: Sendable` mit `static let rootKeyLength = 32` und `static func derive(rootKey: Data) throws -> ChatKeys`
  - Properties: `encKey: SymmetricKey`, `roomId: String`, `token: Data`, `safetyCode: String`, `tokenBase64URL: String`
  - Methoden: `static func generateRootKey() -> Data`, `func encrypt(_ plaintext: Data) throws -> Data`, `func decrypt(_ data: Data) throws -> Data`
  - Hilfsfunktion `func encrypt(_:nonce:)` (internal), nur für Vektortests
  - `public enum CryptoError: Error { case invalidKeyLength, dataTooShort, authenticationFailed }`

- [ ] **Step 1: `tools/vectors/main.go` schreiben.**
  - Verwendet `crypto/hkdf`, `crypto/aes`, `crypto/cipher`, `encoding/binary` (LittleEndian) und `encoding/base32` (StdEncoding.WithPadding(NoPadding)).
  - Eingaben:
    - Root-Key = Bytes `0x00…0x1f`
    - Nonce = `0xa0…0xab`
    - Plaintext = UTF-8 `{"v":1,"kind":"text","text":"Grüße 👋"}`
  - Gibt JSON mit diesen Feldern (Hex) nach stdout aus: `root_key_hex, enc_key_hex, room_id, token_hex, token_b64url, safety_code, base32, nonce_hex, plaintext_utf8, ciphertext_hex`.
  - Zusätzlich einen zweiten Datensatz mit Root-Key = 32 × `0xff`.
- [ ] **Step 2: Erzeugen.**
  - Befehl: `go run ./tools/vectors > client-mac/Tests/ImgShareCoreTests/Resources/vectors.json`
  - Erwartet: JSON-Array mit 2 Objekten. `room_id` hat 32 Hex-Zeichen, `safety_code` passt auf `^\d{3} \d{3} · \d{3} \d{3}$`.
- [ ] **Step 3: `Package.swift` anlegen.**
  - `swift-tools-version: 6.2`, platforms `.macOS("27.0")`
  - Library `ImgShareCore`
  - Testtarget `ImgShareCoreTests` mit `resources: [.copy("Resources")]`
- [ ] **Step 4: Fehlschlagenden Test schreiben** (`ChatKeysTests`, Swift Testing `@Test`).
  - `derivesVectors`: Für jeden Vektor muss `derive(rootKey:)` dieselben Werte für enc, roomId, token, tokenBase64URL und safetyCode liefern.
  - `encryptsVectorWithFixedNonce`: `encrypt(plaintext, nonce:)` muss hex-gleich mit `ciphertext_hex` sein, und `decrypt` muss den Plaintext zurückgeben.
  - `rejectsWrongKeyLength`: 31 Bytes werfen `.invalidKeyLength`.
  - `rejectsShortCiphertext`: 27 Bytes werfen `.dataTooShort`.
  - `tamperedCiphertextFails`: ein Byte umgedreht führt zu `.authenticationFailed`.
  - `randomRoundTrip`: `generateRootKey().count == 32`; `decrypt(encrypt(x)) == x`, und zwei Verschlüsselungen desselben Texts sind verschieden.
- [ ] **Step 5:** `cd client-mac && swift test --filter ChatKeysTests`. Erwartet: Kompilierfehler, weil `ChatKeys` fehlt.
- [ ] **Step 6: `ChatKeys` implementieren.**
  - Ableitung: `HKDF<SHA256>.deriveKey(inputKeyMaterial:salt:info:outputByteCount:)`.
  - Sicherheitscode: `UInt64(littleEndian:)` über `withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }`.
  - Verschlüsseln: `AES.GCM.seal(_, using:, nonce:, authenticating: Data(roomId.utf8))` und davon `.combined`.
  - Entschlüsseln: `AES.GCM.SealedBox(combined:)`.
- [ ] **Step 7:** `swift test --filter ChatKeysTests`. Erwartet: PASS (6 Tests).
- [ ] **Step 8: Commit.** `git add tools/vectors client-mac .gitignore && git commit -m "mac: ChatKeys + Go-Testvektoren"`

### Task 2: KeyFormat (Base32)

**Files:** Create `Sources/ImgShareCore/KeyFormat.swift`, `Tests/ImgShareCoreTests/KeyFormatTests.swift`

**Interfaces:**
- Produces: `public enum KeyFormat { static func format(_ key: Data) -> String; static func parse(_ text: String?) -> Data? }`

- [ ] **Step 1: Tests schreiben.**
  - `formatsVector`: `format(root_key)` muss gleich `vectors[i].base32` sein.
  - Die Ausgabe hat 52 Zeichen in 4er-Gruppen mit `-` (die letzte Gruppe hat 4 Zeichen, insgesamt 13 Gruppen).
  - `roundTrip`: Für 50 zufällige Keys gilt `parse(format(k)) == k`.
  - `parseIsLenient`: `parse` muss alle folgenden Varianten akzeptieren und denselben Key liefern:
    - Kleinbuchstaben
    - Leerzeichen statt `-`
    - `0` statt `O`, `1` statt `I`
    - Zeilenumbrüche
  - `parseRejects`: `parse` liefert `nil` bei:
    - `nil`, `""`, `"   "`
    - einem Zeichen `8` oder `9` (alphanumerisch, aber nicht im Alphabet)
    - einem Key mit 51 Zeichen
    - geändertem letzten Zeichen mit Restbits ≠ 0 (z. B. letztes Zeichen `B` statt `A`, wenn das Original auf `A` endet)
- [ ] **Step 2:** `swift test --filter KeyFormatTests`. Erwartet: FAIL, Kompilierfehler.
- [ ] **Step 3: Implementieren.**
  - Gleiche Bit-Puffer-Logik wie `client/ImgShare.Core/Crypto.cs:73-113`.
  - Alphabet `ABCDEFGHIJKLMNOPQRSTUVWXYZ234567`.
  - Großschreibung über `uppercased()`.
  - Ungültig ist ein Zeichen, wenn es alphanumerisch ist, aber nicht im Alphabet steht (`Character.isLetter || isNumber`).
- [ ] **Step 4:** `swift test --filter KeyFormatTests`. Erwartet: PASS.
- [ ] **Step 5: Commit.** `git commit -am "mac: KeyFormat Base32"` (nach `git add` der neuen Dateien)

### Task 3: Models, JSON-Datumsformat, ImageFormat

**Files:** Create `Models.swift`, `ImageFormat.swift`, `Tests/.../ModelsTests.swift`, `Tests/.../ImageFormatTests.swift`

**Interfaces:**
- Produces (alle `public`, `Codable`, `Sendable`, `Equatable`):
  - `EncryptedMessage { id: Int64; serverTs: Date; ciphertext: String }`
  - `MessagesPage { messages: [EncryptedMessage]; hasMore: Bool }`
  - `PostMessageResult { id: Int64; serverTs: Date }`
  - `BlobResult { blobId: String; size: Int64 }`
  - `enum MessageKind: String { case text, image, read }`. Unbekannte Werte schlagen beim Dekodieren nicht fehl: `Payload.kind` ist `String`, dazu `var messageKind: MessageKind?`.
  - `Payload { v: Int = 1; kind: String; sender: String; senderName: String; sentAt: Date; text: String?; image: ImageInfo?; readUpTo: Int64? }`
  - `ImageInfo { blobId: String; mime: String; filename: String; size: Int64; width: Int; height: Int }`
  - `ChatMessage: Identifiable { id: Int64; serverTs: Date; payload: Payload; isMine: Bool }`
  - `enum ConnectionState { case connecting, online, offline }`
  - `enum WireJSON { static func decoder() -> JSONDecoder; static func encoder() -> JSONEncoder }`
    - CodingKeys in snake_case, ausgeschrieben, ohne `keyDecodingStrategy`.
    - Datumsdekodierung per `.custom`: zuerst `Date.ISO8601FormatStyle(includingFractionalSeconds: true)`, ersatzweise ohne Nachkommastellen. Nachkommastellen über 3 Ziffern werden vorher auf 3 gekürzt (per Regex).
    - Kodiert wird ISO-8601 in UTC mit Millisekunden und `Z`.
  - `enum ImageFormat`:
    - `maxImageBytes = 25_165_824`, `maxPixels = 100_000_000`
    - `detectMime(_ data: Data) -> String?`
    - `safeFileName(_ name: String?, mime: String?) -> String`
    - `formatSize(_ bytes: Int64) -> String`
    - `dimensions(of data: Data) -> (width: Int, height: Int)?` (ImageIO, ohne Dekodieren)
    - `pngData(fromTIFF data: Data) -> Data?`

- [ ] **Step 1: Tests schreiben (`ModelsTests`).**
  - `decodesDotNetPayload`: Das JSON `{"v":1,"kind":"text","sender":"abc","sender_name":"Gerald","sent_at":"2026-11-07T10:00:00.1234567+00:00","text":"Hallo","image":null,"read_up_to":null}` dekodiert.
    - `sentAt` ergibt 2026-11-07 10:00:00.123 UTC (±1 ms).
    - Das ist Review Focus 1.
  - `decodesOffsetTimestamp`: `"2026-11-07T11:00:00+01:00"` ergibt denselben Zeitpunkt wie `"2026-11-07T10:00:00Z"`.
  - `decodesGoServerPage`: `{"messages":[{"id":5,"server_ts":"2026-11-07T10:00:00Z","ciphertext":"AAEC"}],"has_more":true}` dekodiert.
  - `unknownKindDecodes`: `"kind":"reaction"` dekodiert, und `messageKind == nil`.
  - `encodesSnakeCase`: Kodierte Payload-Keys sind exakt `v, kind, sender, sender_name, sent_at, text`. `sent_at` endet auf `Z`.
- [ ] **Step 2: Tests schreiben (`ImageFormatTests`).**
  - `detectsPng` / `detectsJpeg` anhand der Magic Bytes `89 50 4E 47 0D 0A 1A 0A` bzw. `FF D8 FF`.
  - `rejectsGif` (`GIF89a`) und Daten mit weniger als 3 Bytes, Ergebnis jeweils `nil`.
  - `safeFileName`:
    - `("../../etc/passwd.png","image/png")` → `"passwd.png"`
    - `("bild\u{202E}gnp.exe","image/jpeg")` → `"bildgnp.jpg"`
    - `(nil,"image/png")` → `"bild.png"`
    - ein Name mit 200 Zeichen wird zu 80 Zeichen plus Endung
    - `("..png","image/png")` → `"bild.png"`
  - `dimensionsOfTinyPng`: ein eingebettetes 1×1-PNG (Base64-Literal im Test) ergibt `(1,1)`.
  - `tiffToPng`: Ein per `CGImageDestination` erzeugtes 2×2-TIFF ergibt PNG-Daten, die `detectMime` als `"image/png"` erkennt.
- [ ] **Step 3:** `swift test --filter "ModelsTests|ImageFormatTests"`. Erwartet: FAIL, Kompilierfehler.
- [ ] **Step 4: Implementieren.**
  - `safeFileName` folgt `ImageFormat.cs:30-50`:
    - letztes Pfadsegment nach `/` und `\`
    - Scalars der Kategorien `.control` und `.format` sowie `/ \ :` entfernen
    - Endung abschneiden
    - Leerzeichen und Punkte trimmen
    - Fallback `bild`, kürzen auf 80
  - `formatSize`: `B`, `KB` (0 Nachkommastellen), `MB` (1 Nachkommastelle), Dezimaltrennzeichen Komma, wie die deutsche .NET-Kultur.
- [ ] **Step 5:** gleiche Tests laufen lassen. Erwartet: PASS.
- [ ] **Step 6: Commit.** `"mac: Models, Datums-JSON, ImageFormat"`

### Task 4: ApiClient, ApiError, ErrorText, Dev-Server

**Files:**
- Create: `tools/devserver/main.go`, `ApiClient.swift`, `ErrorText.swift`, `ChatTransport.swift`
- Create: `Tests/.../ApiClientTests.swift`, `Tests/.../ErrorTextTests.swift`, `Tests/.../TestServer.swift`

**Interfaces:**
- Consumes: `ChatKeys` (Task 1), Models (Task 3)
- Produces:
  - `public protocol ChatTransport: Sendable` mit:
    - `func postMessage(_ ciphertext: Data) async throws -> PostMessageResult`
    - `func getMessages(after: Int64?, before: Int64?, limit: Int) async throws -> MessagesPage`
    - `func uploadBlob(_ data: Data, progress: (@Sendable (Double) -> Void)?) async throws -> BlobResult`
    - `func getBlob(_ id: String) async throws -> Data`
    - `func connectEvents() async throws -> AsyncThrowingStream<ServerEvent, Error>`
  - `public enum ServerEvent: Sendable { case message(EncryptedMessage), presence(online: Int) }`
  - `public final class ApiClient: ChatTransport`:
    - `init(serverURL: URL, keys: ChatKeys, invite: String?)`
    - `static func validateServerURL(_ s: String) -> Result<URL, ApiError>`
  - `public enum ApiError: Error, Equatable` mit diesen Fällen:
    - `http(status: Int, code: String?)`
    - `invalidServerURL`
    - `httpsRequired`
    - `frameTooLarge`
    - Dazu `var message: String`.
  - `public enum ErrorText { static func describe(_ error: Error) -> String }`
  - `tools/devserver`:
    - Startet mit `go run ./tools/devserver -addr 127.0.0.1:47001 -invite devinvite-0123456789`.
    - Nutzt `store.Open(os.MkdirTemp)` und `server.New(server.Config{… Standardwerte aus main.go, MinFreeBytes: 1, RoomCreateSecret: invite})`.
    - Ausgeliefert wird über `http.ListenAndServe`.
    - Gibt beim Start `listening http://127.0.0.1:47001` aus.

- [ ] **Step 1: `tools/devserver/main.go` schreiben.**
  - Befehl: `go run ./tools/devserver -addr 127.0.0.1:47001 -invite devinvite-0123456789 &` und danach `curl -s http://127.0.0.1:47001/healthz`.
  - Erwartet: `ok`.
- [ ] **Step 2: `TestServer.swift` schreiben.**
  - Enthält `static var url: URL?` aus der Umgebungsvariable `IMGSHARE_TEST_SERVER` und `static let invite = "devinvite-0123456789"`.
  - Integrationstests bekommen `.enabled(if: TestServer.url != nil)`.
- [ ] **Step 3: Tests schreiben (`ErrorTextTests`).** Die Texte sind exakt dieselben wie in `ApiClient.cs:15-25`:
  - 401 → „Zugriff verweigert – passt der Schlüssel?“
  - 403 `invite_required` → „Der Chat existiert auf dem Server noch nicht. Zum Anlegen braucht es den Server-Zugangscode.“
  - 413 → „Datei ist zu groß für den Server.“ (Review Focus 5)
  - 429 → „Zu viele Anfragen, bitte kurz warten.“
  - 507 `quota_exceeded` → „Der Speicher für diesen Chat am Server ist voll.“
  - 507 `room_limit` → „Auf dem Server können keine weiteren Chats angelegt werden.“
  - 507 sonst → „Der Server hat keinen freien Speicher mehr.“
  - 500 `x` → „Serverfehler 500 (x)“
  - `URLError(.cannotConnectToHost)` → „Server nicht erreichbar.“
  - `URLError(.serverCertificateUntrusted)` → „Das Zertifikat des Servers ist ungültig.“
  - `URLError(.timedOut)` → „Der Server antwortet nicht.“
  - `CryptoError.authenticationFailed` → „Daten konnten nicht entschlüsselt werden.“
- [ ] **Step 4: Tests schreiben (`ApiClientTests`).**
  - Unit-Test `validateServerURL`:
    - `https://x.at:47000` wird akzeptiert.
    - `http://127.0.0.1:1` und `http://localhost:1` werden akzeptiert.
    - `http://example.com` → `.httpsRequired`
    - `"kein url"` → `.invalidServerURL`
  - Integrationstests mit frischem zufälligem Root-Key je Test:
    - `createsRoomWithInviteAndPostsMessage`: Ohne Invite wirft `getMessages` den Fehler `.http(403,"invite_required")`. Mit Invite gibt `postMessage` eine id > 0 zurück, und `getMessages(after:0)` enthält den Ciphertext byte-gleich.
    - `wrongTokenIs401`: Ein zweiter Client mit anderem Key, aber derselben `roomId`, bekommt 401. Die `roomId` wird dafür über einen Test-Initializer `ApiClient(serverURL:roomId:token:invite:)` (internal) gesetzt.
    - `blobRoundTrip`: 100 KB Zufallsdaten hochladen. Der Fortschritts-Callback endet bei 1.0, `getBlob` liefert dieselben Bytes.
    - `websocketDeliversMessageAndPresence`: Zwei Clients verbinden `connectEvents()`. Beide sehen `.presence(online: 2)`. Postet A, empfängt B `.message` mit derselben id.
- [ ] **Step 5: Unit-Tests laufen lassen.** `swift test --filter "ErrorTextTests|ApiClientTests"`. Erwartet: FAIL, Kompilierfehler.
- [ ] **Step 6: Implementieren.**
  - `URLSessionConfiguration.ephemeral` mit `timeoutIntervalForRequest = 300`. Die Header Authorization, User-Agent und gegebenenfalls `X-Invite-Code` stehen in `httpAdditionalHeaders` und gelten damit auch für den WebSocket-Upgrade.
  - Die Antwort wird über `bytes(for:)` mit einem 32-MiB-Limit gelesen.
  - Bei Status ≥ 400 wird `{"error":…}` geparst, und der Client wirft `ApiError.http`.
  - Upload über `upload(for:from:delegate:)`. Der Fortschritt kommt aus `URLSessionTaskDelegate.didSendBodyData`.
  - `connectEvents` arbeitet mit `URLSessionWebSocketTask`. Die URL entsteht durch Ersetzen des Schemas: `https`→`wss`, `http`→`ws`. Der Task setzt `maximumMessageSize = 4 MiB`.
  - Eine Lese-Schleife dekodiert `{"type":…}` und ignoriert unbekannte Frames.
  - Eine parallele Ping-Schleife ruft alle **20 s** `sendPing` auf. Ein Fehler beendet den Stream mit Fehler (Review Focus 2).
  - `onTermination` bricht den Task ab.
- [ ] **Step 7: Unit-Tests laufen lassen.** `swift test --filter "ErrorTextTests|ApiClientTests"`. Erwartet: PASS, die Integrationstests werden übersprungen.
- [ ] **Step 8: Integrationstests laufen lassen.**
  - Den Dev-Server starten, dann `IMGSHARE_TEST_SERVER=http://127.0.0.1:47001 swift test --filter ApiClientTests`.
  - Erwartet: PASS (alle Tests).
- [ ] **Step 9: Commit.** `"mac: ApiClient, Fehlertexte, Go-Dev-Server"`

### Task 5: ChatSession – Verarbeitung (mit Fake-Transport)

**Files:** Create `ChatSession.swift`, `Tests/.../FakeTransport.swift`, `Tests/.../ChatSessionTests.swift`

**Interfaces:**
- Consumes: `ChatTransport`, `ServerEvent`, `ChatKeys`, Models, `ImageFormat`
- Produces: `@MainActor @Observable public final class ChatSession`
  - `init(entry: ChatEntryInfo, rootKey: Data, invite: String?, transport: ChatTransport? = nil, cache: BlobCaching? = nil, onLastReadChanged: @escaping (Int64) -> Void)`
    - Ist `transport` nil, wird `ApiClient` verwendet.
    - `ChatEntryInfo` ist ein Wertetyp mit diesen Feldern: `struct ChatEntryInfo: Sendable { id, serverURL: URL, myName, chatName, deviceId: String; lastReadId: Int64 }`.
    - Die Konvertierung aus `ChatEntry` folgt in Task 7.
  - Zustand: `messages: [ChatMessage]` (aufsteigend nach id), `state: ConnectionState`, `otherOnline: Bool`, `otherReadUpTo: Int64`, `hasOlder: Bool`, `isLoaded: Bool`, `lastError: String?`, `unreadCount: Int`, `keys: ChatKeys`
  - `var onNewMessage: ((ChatMessage, _ live: Bool) -> Void)?`, ein Hook für Benachrichtigungen
  - Methoden:
    - `func run() async`: Verbindungsschleife bis zum Abbruch
    - `func stop()`
    - `func loadOlder() async throws`
    - `func sendText(_:) async throws -> Int64`
    - `func sendImage(_ data: Data, fileName: String, progress: (@Sendable (Double) -> Void)?) async throws -> Int64`
    - `func markRead() async`
    - `func imageData(for: ImageInfo) async throws -> Data`
    - `static func testConnection(serverURL: URL, rootKey: Data, invite: String?) async throws`
  - `public protocol BlobCaching: Sendable { func read(room: String, blobId: String) -> Data?; func write(room: String, blobId: String, data: Data); func remove(room: String, blobId: String) }`. Die echte Implementierung folgt in Task 7, die Tests nutzen eine In-Memory-Variante.
  - `FakeTransport` ist ein Actor mit einer `[EncryptedMessage]`-Liste, auto-inkrementierten ids, einem steuerbaren Event-Stream (`emit(_:)`, `fail()`) und `postedCount`.

- [ ] **Step 1: Tests schreiben (`ChatSessionTests`).** Jeder Test baut Ciphertexts mit denselben `ChatKeys`.
  - `initialLoadDecryptsAndSorts`: Der Fake enthält die ids 3, 1 und 2 (Text). Nach dem ersten Laden ist `messages.map(\.id) == [1,2,3]` und `isLoaded == true`.
  - `dedupsPostEcho`: `sendText("hi")`. Anschließend schickt der Fake dieselbe id als `.message`-Event. Es gibt dann genau eine Nachricht, und `isMine == true`.
  - `ignoresGarbage` (Review Focus 3): Keine dieser Nachrichten erscheint, und `run` läuft weiter:
    - zufälliger Ciphertext
    - gültiger Payload mit `kind:"reaction"`
    - `text:""`
    - Bild mit `blob_id:"../x"`
    - Ciphertext mit 27 Bytes
  - `readReceipts`:
    - Ein fremdes `read` mit `read_up_to:7` setzt `otherReadUpTo` auf 7.
    - Ein späteres fremdes `read` mit 5 ändert nichts.
    - Ein eigenes `read` ändert `otherReadUpTo` nicht.
  - `unreadAndMarkRead`:
    - Zwei fremde Nachrichten ergeben `unreadCount == 2`.
    - `markRead()` setzt `unreadCount` auf 0, ruft `onLastReadChanged(<max fremde id>)` auf und postet genau ein `read` mit `read_up_to` = max.
    - Ein zweites `markRead()` postet nichts.
  - `presenceThreshold`: `.presence(online:1)` ergibt `otherOnline == false`, `.presence(online:2)` ergibt `true`.
  - `reconnectsWithBackoffAndCatchesUp`:
    - Ablauf: Der Fake beendet den Stream mit Fehler und legt id 10 ab.
    - Erwartet: `state` geht über `.offline` zurück auf `.online`, und id 10 erscheint genau einmal.
    - Der Backoff ist injizierbar über `init(..., backoff: Backoff = .default)`; im Test kommt `Backoff(initial: .milliseconds(1), max: .milliseconds(4))` zum Einsatz.
  - `loadOlderPrepends`:
    - Vorbereitung: Der Fake hat die ids 1…250 (die erste Seite liefert 51…250 und `has_more`).
    - `loadOlder()` lädt 100 Nachrichten.
    - Erwartet: `messages.first?.id == 1` nach einem weiteren `loadOlder()`, danach `hasOlder == false`.
  - `sendImageRejectsNonImage`: GIF-Daten führen zum Fehler `ImageError.unsupportedFormat` mit der Meldung „Nur PNG und JPG werden unterstützt.“
  - `sendImageRejectsTooLarge`: 25 165 825 Bytes PNG-Header plus Füllbytes führen zu `ImageError.tooLarge` mit „Bild ist größer als 24 MB.“
  - `imageDataUsesCacheAndDropsCorrupt`:
    - Ein korrupter Cache-Eintrag wird entfernt und neu geladen.
    - Ergebnis sind die entschlüsselten PNG-Bytes.
    - Der neue Eintrag landet im Cache.
  - `imageDataRejectsPixelBomb`: Ein PNG mit dem Header 20000×20000 (nur der IHDR ist nötig, als Test-Fixture) führt zu `ImageError.tooManyPixels`.
- [ ] **Step 2:** `swift test --filter ChatSessionTests`. Erwartet: FAIL, Kompilierfehler.
- [ ] **Step 3: Implementieren.**
  - Die Logik entspricht `client/ImgShare.Core/ChatSession.cs:67-331`, darunter `process(_:live:)` mit `seen`-Set, `minSeenId`/`maxSeenId` und `myReadUpTo`.
  - Die Nachrichten liegen in einem Dictionary `[Int64: ChatMessage]`, daraus wird das sortierte Array `messages` berechnet.
  - `onNewMessage` wird nur nach dem ersten Laden aufgerufen, nur für fremde Nachrichten und nur bei `live == true`.
  - `ImageError` ist ein `enum` mit `message`-Texten; `ErrorText.describe` bildet ihn auf deutsche Texte ab.
- [ ] **Step 4:** `swift test --filter ChatSessionTests`. Erwartet: PASS.
- [ ] **Step 5: Commit.** `"mac: ChatSession"`

### Task 6: ChatSession gegen den echten Server

**Files:** Create `Tests/.../ChatSessionIntegrationTests.swift`

**Interfaces:** Consumes `ChatSession`, `ApiClient`, `TestServer` (Tasks 4, 5)

- [ ] **Step 1: Test `twoSessionsChat` schreiben.**
  - Zwei Sessions A und B mit demselben Root-Key, aber unterschiedlicher `deviceId`, beide mit Invite.
  - Beide starten `run()` in einem Task. Erwartet wird jeweils `state == .online`; gepollt wird mit einem Timeout von 5 s.
  - Dann wird geprüft:
    - `otherOnline` ist auf beiden Seiten `true`.
    - Sendet A `sendText("Grüße 👋")`, erhält B diese Nachricht mit `isMine == false`.
    - B ruft `markRead()` auf; danach ist bei A `otherReadUpTo` gleich dieser id.
    - Sendet A ein 1×1-PNG per `sendImage`, liefert `B.imageData` dieselben Bytes.
- [ ] **Step 2: Test `recoversAfterConnectionDrop` schreiben (Review Focus 2).**
  - Der Dev-Server bekommt das Flag `-drop-after <dauer>`. Damit umhüllt er den `net.Listener`, und jede angenommene Verbindung wird per `time.AfterFunc(d, conn.Close)` nach der angegebenen Dauer hart geschlossen. Das simuliert einen Ruhezustand bzw. Netzabriss. Der Standardwert `0` schaltet das aus.
  - Erwartet:
    - Session A geht auf `.offline` und dann wieder auf `.online`.
    - Eine Nachricht, die B in der Zwischenzeit gesendet hat, erscheint bei A genau einmal.
- [ ] **Step 3: Tests laufen lassen.**
  - Ein Dev-Server läuft normal auf `:47001`, ein zweiter auf `:47002` mit `-drop-after 2s`. `TestServer` liest die Adresse des zweiten aus `IMGSHARE_TEST_SERVER_FLAKY`.
  - Befehl: `IMGSHARE_TEST_SERVER=http://127.0.0.1:47001 IMGSHARE_TEST_SERVER_FLAKY=http://127.0.0.1:47002 swift test --filter ChatSessionIntegrationTests`
  - Erwartet: PASS.
- [ ] **Step 4: Commit.** `"mac: Integrationstests ChatSession"`

### Task 7: Speicher – AppConfig, Keychain, BlobCache

**Files:**
- Create: `Storage/AppConfig.swift`, `Storage/KeychainStore.swift`, `Storage/BlobCache.swift`
- Create: `Tests/.../StorageTests.swift`

**Interfaces:**
- Produces:
  - `public struct ChatEntry: Codable, Identifiable, Sendable`:
    - Felder: `id: String` (UUID ohne Bindestriche, klein), `serverURL: String`, `myName`, `chatName`, `deviceId: String` (UUID ohne Bindestriche, klein), `lastReadId: Int64`
    - `var info: ChatEntryInfo? { get }` (ist nil, wenn die URL ungültig ist)
  - `public struct AppConfig: Codable, Sendable { chats: [ChatEntry]; notificationsPaused: Bool }`, mit diesen statischen Funktionen:
    - `static func load(from dir: URL) -> AppConfig`
    - `func save(to dir: URL) throws`
    - `static var configDir: URL`
    - `static var cacheDir: URL` (beachtet `IMGSHARE_HOME`)
  - `public struct KeychainStore: Sendable` mit:
    - `init(service: String = "at.mediatesystems.imgshare")`
    - `func set(_ data: Data, account: String) throws`
    - `func get(account: String) throws -> Data?`
    - `func delete(account: String)`
    - `func rootKey(chatId:) throws -> Data`; wirft `StorageError.keyMissing` mit dem Text „Schlüssel nicht gefunden – bitte Chat neu einrichten.“
    - `func setRootKey(_:chatId:)`, `func invite(chatId:) -> String?`, `func setInvite(_:chatId:)`, `func removeAll(chatId:)`
  - `public struct BlobCache: BlobCaching { init(root: URL) }`

- [ ] **Step 1: Tests schreiben (`StorageTests`).**
  - `configRoundTrip`: speichern und laden im Temp-Ordner; die Werte sind gleich.
  - `configIsAtomic`: Nach `save` existiert keine `.tmp`-Datei.
  - `corruptConfigIsBackedUp` (Review Focus 4): In `config.json` steht `{kaputt`. `load` gibt eine leere Config zurück, und `config.json.bak` enthält `{kaputt`.
  - `missingConfigIsEmpty`.
  - `keychainRoundTrip`: läuft mit dem Service `at.mediatesystems.imgshare.tests.<uuid>`. Prüft `set`/`get`/`delete`. Nach `delete` liefert `get` nil, und `rootKey(chatId:)` wirft `.keyMissing`.
  - `blobCacheRoundTripAndRemove`.
  - `blobCacheRejectsUnsafeId`: `write(room:"r", blobId:"../x")` schreibt nichts außerhalb von `root`.
- [ ] **Step 2:** `swift test --filter StorageTests`. Erwartet: FAIL, Kompilierfehler.
- [ ] **Step 3: Implementieren.**
  - Das Speichern schreibt erst `config.json.tmp` und ersetzt dann per `FileManager.replaceItemAt` bzw. `moveItem`.
  - Die JSON-Keys sind camelCase; es gibt keine Kompatibilitätspflicht zu Windows.
  - Keychain mit `kSecClassGenericPassword` und `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, ohne Synchronisierung.
  - BlobCache: Die blobId wird gegen `^[A-Za-z0-9-]{1,64}$` geprüft, die roomId gegen `^[0-9a-f]{32}$`.
- [ ] **Step 4:** `swift test --filter StorageTests`. Erwartet: PASS.
- [ ] **Step 5: Commit.** `"mac: Config, Keychain, BlobCache"`

### Task 8: App-Gerüst, Menüleiste, AppModel, Autostart, Setup

**Files:**
- Create: `client-mac/project.yml`, `ImgShareMac/ImgShareMacApp.swift`, `AppModel.swift`, `MenuBarContent.swift`, `LoginItem.swift`
- Create: `Setup/SetupView.swift`, `Setup/QRCodeView.swift`, `Info.plist`, `Assets.xcassets` (AppIcon und die Template-Bilder `MenuIcon` und `MenuIconUnread`)

**Interfaces:**
- Consumes: `AppConfig`, `ChatEntry`, `KeychainStore`, `ChatSession`, `KeyFormat`, `ChatKeys`, `ApiClient.validateServerURL`, `ErrorText`
- Produces:
  - `@MainActor @Observable final class AppModel`:
    - Zustand: `config: AppConfig`, `sessions: [String: ChatSession]` (Schlüssel `chatId`), `totalUnread: Int`
    - `func start()`, `func addOrUpdate(entry: ChatEntry, rootKey: Data, invite: String?)`, `func remove(chatId:)`, `func chatWithMostUnread() -> String?`
    - `func setNotificationsPaused(_:)`, `func saveConfig()`
  - Fenster-IDs: `"chat"` (WindowGroup mit dem Wert `String` = chatId) und `"setup"` (WindowGroup mit dem Wert `String?`; nil steht für einen neuen Chat)

- [ ] **Step 1: `project.yml` anlegen.**
  - Target `ImgShareMac`, application, macOS 27.0, Swift 6, lokales Package `../client-mac` (Produkt `ImgShareCore`).
  - Info.plist:
    - `LSUIElement: YES`
    - `IMGSHAREDefaultServer: $(IMGSHARE_DEFAULT_SERVER)`, Standardwert `""`
  - Signierung: `CODE_SIGN_IDENTITY: "-"`, `ENABLE_HARDENED_RUNTIME: YES`.
  - **Keine App-Sandbox.** Grund: Kein App Store, und `IMGSHARE_HOME` soll auf beliebige Ordner zeigen können (Tests, zweite Instanz).
  - Build-Befehl: `cd client-mac && xcodegen && xcodebuild -project ImgShareMac.xcodeproj -scheme ImgShareMac -configuration Debug build`. Erwartet: `BUILD SUCCEEDED` mit einem leeren `MenuBarExtra`.
- [ ] **Step 2: AppModel und Menü.**
  - Das `MenuBarExtra` verwendet `.menu`-Style. Das Label ist `Image("MenuIcon")` bzw. `"MenuIconUnread"`, wenn `totalUnread > 0`.
  - Inhalt des Menüs:
    - je Chat ein Eintrag „\(chatName)“ bzw. „\(chatName) (\(unread))“
    - Trenner
    - „Neuen Chat einrichten…“
    - „Mitteilungen pausieren“ (Toggle)
    - „Beim Anmelden starten“ (Toggle über `LoginItem`, also `SMAppService.mainApp` register/unregister/status)
    - Trenner
    - „Beenden“ (⌘Q)
  - `AppModel.start()` lädt die Config. Für jeden Chat holt es den Key aus dem Keychain und startet `Task { await session.run() }`.
  - Bei einem Keychain-Fehler wird keine Session gestartet. Der Menüeintrag zeigt dann „\(chatName) – Schlüssel fehlt“ und öffnet das Setup (Review Focus 4).
  - Ist die Config leer, öffnet sich beim Start das Setup-Fenster.
- [ ] **Step 3: SetupView**, analog zu `client/ImgShare/Ui/SetupWindow.xaml.cs`.
  - Felder:
    - Server-Adresse, vorbelegt mit `IMGSHAREDefaultServer` oder `https://`
    - Mein Name, Chat-Name
    - Schlüssel mit „Neu erzeugen“ und „Einfügen“
    - Server-Zugangscode (optional, `SecureField`)
  - Anzeige: Sicherheitscode (live aus dem geparsten Key) und der QR-Code des formatierten Keys über `CIFilter.qrCodeGenerator()` mit `correctionLevel = "M"`, ohne Interpolation skaliert.
  - Buttons:
    - „Schlüssel kopieren“ setzt `NSPasteboard` mit `.string` und dem Typ `org.nspasteboard.ConcealedType`. Nach 60 s wird geleert, sofern die `changeCount` unverändert ist.
    - „Verbindung testen“ ruft `ChatSession.testConnection` auf und zeigt „Verbindung OK“ bzw. `ErrorText.describe`.
    - „Speichern“ ist deaktiviert, solange URL, Key oder Namen ungültig sind.
    - „Chat entfernen“ (nur beim Bearbeiten) mit Bestätigungsdialog.
- [ ] **Step 4: Manuell prüfen.**
  - Den Dev-Server starten und die App mit `IMGSHARE_HOME=$(mktemp -d)` im Xcode-Scheme bzw. per `open --env` starten.
  - Prüfen:
    - Das Setup öffnet sich.
    - Ein neuer Key mit der Adresse `http://127.0.0.1:47001` und dem Invite besteht den Verbindungstest.
    - Nach dem Speichern zeigt das Menü den Chat.
    - Nach einem Neustart der App ist der Chat noch da; der Key kommt aus dem Keychain.
- [ ] **Step 5: Commit.** `"mac: App-Gerüst, Menüleiste, Setup"`

### Task 9: Chat-Fenster

**Files:**
- Create: `Chat/ChatView.swift`, `MessageRow.swift`, `ComposerView.swift`, `ChatViewModel.swift`, `PasteboardImage.swift`
- Create: `Sources/ImgShareCore/Presentation/DayLabel.swift`, `Tests/.../DayLabelTests.swift`
- Create: `Sources/ImgShareCore/Presentation/OutgoingQueue.swift`, `Tests/.../OutgoingQueueTests.swift`

**Interfaces:**
- Consumes: `ChatSession` (Task 5), `AppModel` (Task 8), `ImageFormat`
- Produces:
  - `public enum DayLabel { static func text(for date: Date, now: Date, calendar: Calendar) -> String }`. Liefert „Heute“, „Gestern“ oder sonst `date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())` mit Locale `de_AT`.
  - `@MainActor @Observable public final class OutgoingQueue`:
    - Zustand: `items: [OutgoingItem]`
    - `OutgoingItem { id: UUID; kind: .text(String) | .image(Data, fileName: String); progress: Double; error: String? }`
    - Methoden:
      - `func enqueue(_:)`
      - `func process(using send: (OutgoingItem, @Sendable (Double) -> Void) async throws -> Void) async`
      - `func retry(_ id: UUID)`
      - `func discard(_ id: UUID)`
    - Fehlgeschlagene Einträge bleiben stehen und tragen den Fehlertext.
  - `enum PasteboardImage { static func read(from pb: NSPasteboard) -> (Data, fileName: String)?; static func read(fileURL: URL) throws -> (Data, String) }`
    - Reihenfolge: zuerst eine Datei-URL mit PNG oder JPEG, dann `.png`, dann `.tiff`. TIFF wird per `ImageFormat.pngData(fromTIFF:)` umgewandelt.
    - Der Dateiname ist `Bild yyyy-MM-dd HH.mm.ss.png` oder der Originalname.

- [ ] **Step 1: Tests schreiben (`DayLabelTests`).**
  - Gleicher Tag → „Heute“, Vortag → „Gestern“.
  - Für den 2026-11-01 bei `now` = 2026-11-07 → „Sonntag, 1. November 2026“.
- [ ] **Step 2: Tests schreiben (`OutgoingQueueTests`)** (Review Focus 5).
  - Ein Send-Closure, das `ApiError.http(status:413,code:nil)` wirft, lässt den Eintrag mit `error == "Datei ist zu groß für den Server."` in `items`.
  - `retry` mit einem erfolgreichen Closure entfernt ihn.
  - Der Fortschritt wird weitergereicht.
  - Die Reihenfolge der Einträge bleibt FIFO.
- [ ] **Step 3:** `swift test --filter "DayLabelTests|OutgoingQueueTests"`. Erwartet zuerst FAIL. Dann implementieren, bis PASS.
- [ ] **Step 4: ChatView bauen.**
  - Grundaufbau:
    - Eine `ScrollView` mit `LazyVStack` zeigt die Nachrichten, mit Tagestrennern über `DayLabel`.
    - Der Titel zeigt Chat-Name und Status: „online“ bei `otherOnline`, sonst „verbunden“ bzw. „getrennt – \(lastError)“.
  - Nachrichten:
    - Eigene Nachrichten stehen rechts in Akzentfarbe, fremde links.
    - Die Uhrzeit wird mit `HH:mm` angezeigt.
    - Eigene Nachrichten zeigen ✓ für zugestellt (id > 0) und ✓✓ für gelesen (`id <= otherReadUpTo`).
    - Text wird als `AttributedString` dargestellt, in dem nur Links, die `NSDataDetector` erkennt, ein `.link` bekommen. **Kein** `AttributedString(markdown:)`, damit fremder Text nicht als Markdown interpretiert wird.
    - Bilder erscheinen als Vorschau, maximal 320 pt breit. Geladen wird über `session.imageData` mit einem Platzhalter während des Ladens; ein Klick öffnet den Viewer (Task 10).
  - Scrollen:
    - Erreicht die Liste ganz oben das erste Element, wird `loadOlder()` aufgerufen. Danach wird die Scroll-Position auf das vorherige erste Element gehalten (`scrollPosition(id:)`).
    - Der Button „Nach unten“ erscheint, wenn die Liste nicht am Ende steht.
  - Suche über `.searchable` mit ⌘F. Sie filtert die Textnachrichten, ohne Groß-/Kleinschreibung und ohne Akzente zu unterscheiden.
  - Composer:
    - Ein mehrzeiliges `TextField`; Enter sendet, ⇧Enter erzeugt einen Zeilenumbruch.
    - Ein Büroklammer-Button öffnet den `fileImporter` für `.png` und `.jpeg`.
    - `.onPasteCommand`/`.pasteDestination`: Bilddaten im Pasteboard landen als Bildvorschau.
    - `.dropDestination(for: URL.self)` nimmt Bilddateien an.
    - Das ausgewählte Bild erscheint als Vorschau mit „Senden“ und „Verwerfen“.
    - `OutgoingQueue` zeigt den Fortschritt und bei Fehlern „Erneut senden“.
    - Der Textentwurf wird erst geleert, wenn das Senden erfolgreich war.
  - Wenn das Fenster aktiv wird oder eine neue Nachricht eintrifft, während es aktiv ist, wird `session.markRead()` aufgerufen.
  - Schließen beendet nur das Fenster, die App läuft weiter. Die Fensterposition wird über `defaultWindowPlacement` bzw. die automatische Wiederherstellung gesetzt.
- [ ] **Step 5: Manuell prüfen.**
  - Zwei App-Instanzen mit unterschiedlichem `IMGSHARE_HOME` und demselben Key gegen den Dev-Server laufen lassen. Alternativ dient der `say`-Modus über die Integrationstest-Session.
  - Prüfen:
    - Text in beide Richtungen
    - Bild per ⌘V (Screenshot mit ⌃⇧⌘4), per Drag & Drop aus dem Finder und per Dateidialog
    - Häkchen werden zu ✓✓
    - Ältere Nachrichten nach 250 Nachrichten (per Skript seeden)
    - Suche
    - Links öffnen im Browser
    - Dunkelmodus
- [ ] **Step 6: Commit.** `"mac: Chat-Fenster"`

### Task 10: Bildanzeige und Mitteilungen

**Files:**
- Create: `Viewer/ImageViewerView.swift`, `Notifications.swift`
- Create: `Sources/ImgShareCore/Presentation/NotificationBatcher.swift`, `Tests/.../NotificationBatcherTests.swift`

**Interfaces:**
- Consumes: `ChatSession.onNewMessage`, `AppModel`, `ImageFormat.safeFileName`
- Produces:
  - `public struct NotificationBatcher { mutating func add(chatName: String, message: ChatMessage) -> NotificationContent?; mutating func reset(chatId:) }`
  - `public struct NotificationContent: Equatable { title: String; body: String; threadId: String }`

- [ ] **Step 1: Tests schreiben (`NotificationBatcherTests`).** Regeln wie `App.xaml.cs:108-120`:
  - Die erste Nachricht ergibt title = „\(senderName) in \(chatName)“. Der body ist der Text; bei mehr als 120 Zeichen wird auf 119 Zeichen plus „…“ gekürzt. Bei einem Bild lautet der body „📷 Bild“.
  - Die zweite Nachricht ohne `reset` ergibt den body „2 neue Nachrichten“. `threadId` ist gleich, damit macOS die Mitteilungen gruppiert und ersetzt.
  - Nach `reset(chatId:)` beginnt die Zählung wieder bei 1.
- [ ] **Step 2:** `swift test --filter NotificationBatcherTests`. Erwartet zuerst FAIL, dann implementieren, bis PASS.
- [ ] **Step 3: `Notifications.swift`.**
  - Beim ersten Chat wird um Erlaubnis gefragt (`requestAuthorization([.alert,.sound,.badge])`).
  - Gepostet wird nur, wenn die Mitteilungen nicht pausiert sind und das Chat-Fenster dieses Chats nicht key ist.
  - Der `UNNotificationRequest`-Identifier ist `threadId`, damit die Mitteilung ersetzt statt gestapelt wird.
  - Ein Klick auf die Mitteilung öffnet über `userNotificationCenter(_:didReceive:)` das Chat-Fenster.
  - `markRead` bzw. das Aktivieren des Fensters ruft `reset` auf und entfernt die zugestellten Mitteilungen dieses Threads.
- [ ] **Step 4: ImageViewerView.**
  - Ein eigenes Fenster (`WindowGroup` mit dem Wert `ImageRef {chatId, blobId}`).
  - Das Bild wird skaliert angezeigt und lässt sich per Pinch zoomen.
  - Toolbar:
    - „Kopieren“ (⌘C) schreibt PNG bzw. JPEG ins Pasteboard.
    - „Sichern unter…“ (⌘S) nutzt `fileExporter` mit dem Standardnamen `ImageFormat.safeFileName`.
    - Esc schließt das Fenster.
  - Vor dem Anzeigen wird `ImageFormat.dimensions` gegen `maxPixels` geprüft; das ist schon in `session.imageData` (Task 5) passiert.
- [ ] **Step 5: Manuell prüfen.**
  - Bei inaktivem Fenster erscheint eine Mitteilung; drei Nachrichten ergeben eine Mitteilung „3 neue Nachrichten“.
  - Ein Klick öffnet den Chat.
  - Sind die Mitteilungen pausiert, erscheint keine.
  - Das Bild öffnet sich, lässt sich kopieren und sichern; der Dateiname ist bereinigt.
- [ ] **Step 6: Commit.** `"mac: Bildanzeige, Mitteilungen"`

### Task 11: CI, README, Interop-Abnahme

**Files:**
- Create: `.github/workflows/mac-client.yml`
- Modify: `README.md` (Ordnertabelle und neuer Abschnitt „macOS client“)

- [ ] **Step 1: Workflow anlegen.**
  - `on: push` (main), Tags `v*`, `workflow_dispatch`.
  - Läuft auf `macos-latest`. Xcode wird per `sudo xcode-select -s /Applications/Xcode_27*.app` ausgewählt.
  - `actions/setup-go` mit `go-version-file: go.mod`.
  - Ablauf:
    - Dev-Server im Hintergrund starten (beide Ports).
    - `IMGSHARE_TEST_SERVER=… IMGSHARE_TEST_SERVER_FLAKY=… swift test --package-path client-mac` ausführen.
    - `brew install xcodegen`, dann `xcodegen --spec client-mac/project.yml`.
    - `xcodebuild -scheme ImgShareMac -configuration Release -derivedDataPath build IMGSHARE_DEFAULT_SERVER="${{ vars.IMGSHARE_DEFAULT_SERVER }}" CODE_SIGN_IDENTITY=- build`.
    - `ditto -c -k --keepParent ImgShare.app ImgShare-mac.zip` und `shasum -a 256`.
    - Artefakt mit `retention-days: 14`.
  - Bei Tags hängt ein Release-Upload per `gh release upload --clobber` (wie `windows-client.yml:73-97`) die Datei an das Release.
- [ ] **Step 2: README ergänzen.** Der Abschnitt „macOS client“ beschreibt:
  - den Build (lokal per xcodegen und xcodebuild)
  - wie die Tests laufen (Dev-Server plus `swift test`)
  - den ersten Start: Rechtsklick → Öffnen bzw. Systemeinstellungen → Datenschutz & Sicherheit → „Dennoch öffnen“, oder `xattr -dr com.apple.quarantine ImgShare.app`
  - Speicherorte und Keychain

  Die Ordnertabelle bekommt die Zeilen `client-mac/`, `tools/vectors` und `tools/devserver`.
- [ ] **Step 3: Lokal verifizieren.**
  - Die Befehle des Workflows lokal ausführen.
  - Erwartet: alle Tests PASS, `BUILD SUCCEEDED`. Das ZIP lässt sich entpacken und starten.
- [ ] **Step 4: Interop-Abnahme durch den Nutzer** (manuell, auf dem echten Server).
  - Der Windows-Client erzeugt den Schlüssel, der Mac fügt ihn ein. Der Sicherheitscode muss auf beiden Seiten identisch sein.
  - Dann prüfen:
    - Text und Bild in beide Richtungen
    - Lesebestätigung in beide Richtungen
    - Umlaute und Emoji
- [ ] **Step 5: Commit.** `"mac: CI-Workflow und README"`
