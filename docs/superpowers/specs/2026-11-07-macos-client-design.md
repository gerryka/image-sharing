# Plan: ImgShare für macOS (Swift)

## Context
ImgShare ist ein Ende-zu-Ende-verschlüsselter Bild- und Text-Chat für zwei Personen. Er besteht aus einem Go-Relay-Server und einem Windows-Client (.NET 10, WPF). Neu dazu kommt ein **nativer macOS-Client in Swift**. Er spricht mit dem unveränderten Server und ist protokollkompatibel zum Windows-Client, sodass ein Mac und ein Windows-PC im selben Chat sind. Die App soll sich **Mac-typisch** anfühlen und den Windows-Client nicht 1:1 nachbauen.

Entscheidungen des Nutzers:
- Menüleisten-App, kein Dock-Symbol
- Verteilung unsigniert bzw. ad-hoc signiert, ohne Developer-Account
- Nur das aktuelle macOS

Meine eigenen Entscheidungen (markiert mit *Annahme*):
- SwiftUI
- Swift Concurrency
- keine Fremdbibliotheken außer für QR-Codes, und auch die nur, falls CoreImage nicht reicht
- *Annahme:* Die Oberfläche ist zunächst auf Deutsch, wie beim Windows-Client.

**Nicht in v1:**
- Teilen-Menü (Share Extension)
- Screenshot-Tastenkürzel
- Antworten aus der Mitteilung
- App Store
- Löschen oder Ablauf von Nachrichten (gibt es auch im Protokoll v1 nicht, siehe `docs/PROTOCOL.md:200`)

## Struktur im Repo
```
client-mac/
  Package.swift                 # SwiftPM: ImgShareCore (Library) + Tests
  Sources/ImgShareCore/         # UI-frei, mit `swift test` testbar
  Tests/ImgShareCoreTests/
  ImgShareMac/                  # App-Target (Xcode-Projekt, nutzt ImgShareCore als lokales Package)
  ImgShareMac.xcodeproj
```
Die Aufteilung folgt der vorhandenen Trennung in `client/ImgShare.Core` und `client/ImgShare`.

## Schritt 1: ImgShareCore (Port von `client/ImgShare.Core`)
Die Vorlage ist jeweils die C#-Datei und `docs/PROTOCOL.md`. Alles muss byte-genau kompatibel sein.

- **`Crypto.swift`** (Port von `Crypto.cs`):
  - HKDF\<SHA256\> mit Salt `"imgshare-v1"`. Abgeleitet werden `enc` (32 B), `room` (16 B, als Hex in Kleinbuchstaben), `auth` (32 B) und `safety` (8 B).
  - Der Sicherheitscode wird aus den 8 `safety`-Bytes als UInt64 in **Little-Endian** gelesen, dann `% 10^12`. Angezeigt wird er als `"123 456 · 789 012"` (Mittelpunkt U+00B7).
  - Verschlüsselt wird mit AES.GCM: Nonce 12 B, AAD = room_id als ASCII. `SealedBox.combined` ergibt genau das Format `nonce‖ct‖tag`.
- **`KeyFormat`** (Port von `Crypto.cs:71-114`):
  - Base32 nach RFC 4648 ohne Padding, Gruppen zu je 4 Zeichen mit `-`.
  - Beim Einlesen: in Großbuchstaben umwandeln, `0` wird zu `O`, `1` wird zu `I`.
  - Nicht-alphanumerische Zeichen werden ignoriert.
  - Das Ergebnis muss genau 32 B lang sein, und die Restbits müssen 0 sein.
- **`ApiClient.swift`** (Port von `ApiClient.cs`), auf Basis von `URLSession`:
  - Header bei jedem Request:
    - `Bearer` mit dem Token als base64url ohne Padding
    - `X-Invite-Code`, falls gesetzt
    - User-Agent `ImgShare/1.0`
  - Endpunkte: Nachrichten POST/GET mit `after`/`before`/`limit` sowie Blobs POST/GET.
  - Upload mit Fortschrittsanzeige.
  - Es gilt https; http ist nur für Loopback erlaubt.
  - WebSocket über `URLSessionWebSocketTask` mit Auth-Header. Er verarbeitet die Frames `message` und `presence`.
  - Fehler im Format `{"error":code}` werden auf deutsche Texte abgebildet (Port von `ErrorText.cs`).
- **`Models.swift`** (Port von `Models.cs`):
  - Codable-Typen für das Serverformat und die Klartext-JSON: `v`, `kind` (`text`/`image`/`read`), `sender`, `sender_name`, `sent_at`, `text`, `image{…}`, `read_up_to`.
  - Die Feldnamen müssen exakt stimmen.
- **`ChatSession.swift`** (Port von `ChatSession.cs`), als `@Observable`-Klasse bzw. Actor:
  - Verbindungsschleife: Verlauf nachholen (`before=Int64.max`), WebSocket öffnen, erneut nachholen.
  - Wiederverbinden mit Backoff von 1 bis 30 s.
  - Doppelte Nachrichten werden über die ID verworfen.
  - Lesebestätigungen, „Ältere laden“, Online-Status ab `online >= 2`.
  - `blob_id` muss zu `^[A-Za-z0-9-]{1,64}$` passen.
- **`ImageFormat.swift`**:
  - Erkennung von PNG und JPEG an den Magic Bytes.
  - Grenzen: max. 24 MiB und 100 Mio. Pixel.
  - `SafeFileName`.
- **`Storage`**:
  - Die Konfiguration liegt in `~/Library/Application Support/ImgShare/config.json` und wird atomar geschrieben. Gespeichert werden ServerUrl, MyName, ChatName, DeviceId und LastReadId pro Chat.
  - **Root-Key und Invite-Code kommen in den Keychain** (Ersatz für `Dpapi.cs`).
  - Der Blob-Cache liegt verschlüsselt in `~/Library/Caches/ImgShare/<room>/<blob_id>`.
  - Der Chat-Verlauf wird, wie unter Windows, nicht lokal gespeichert.

## Schritt 2: Mac-App (Gegenstück zu `client/ImgShare`, aber Mac-typisch)
- **Menüleiste**:
  - `MenuBarExtra` mit `LSUIElement` (kein Dock-Symbol).
  - Das Symbol hat eine eigene Variante bzw. einen Badge für Ungelesenes.
  - Das Menü listet die Chats mit Ungelesen-Zähler, dazu „Neuen Chat einrichten“, „Mitteilungen pausieren“, „Beim Anmelden starten“ und „Beenden“.
  - Ein Klick öffnet den Chat mit den meisten ungelesenen Nachrichten.
- **Chat-Fenster** (SwiftUI `Window`/`WindowGroup` pro Chat):
  - Bilder per ⌘V (NSPasteboard: PNG, TIFF, das in PNG umgewandelt wird, oder Datei-URL), per Drag & Drop oder über `fileImporter`.
  - Vorschau vor dem Senden, Fortschritt beim Upload, erneut senden bei Fehler.
  - Suche mit ⌘F, Tagestrenner, Häkchen für zugestellt und gelesen, anklickbare Links.
  - Ältere Nachrichten laden sich beim Hochscrollen nach.
  - Hell/Dunkel folgt automatisch dem System.
  - Schließen versteckt das Fenster nur; die Fensterposition stellt macOS selbst wieder her.
- **Bildanzeige**: Quick Look (`QLPreviewPanel`) bzw. ein eigenes Fenster mit Kopieren und „Sichern unter…“.
- **Setup-Fenster**:
  - Schlüssel erzeugen oder einfügen, Sicherheitscode anzeigen.
  - QR-Code über CoreImage `CIQRCodeGenerator` mit Korrekturstufe M.
  - Kopierter Schlüssel wird nach 60 s aus der Zwischenablage gelöscht. Dabei wird `org.nspasteboard.ConcealedType` gesetzt, damit Clipboard-Manager und Universelle Zwischenablage ihn ignorieren.
  - Dazu Verbindungstest, Feld für den Invite-Code und „Chat entfernen“.
- **Mitteilungen** über `UNUserNotificationCenter`:
  - nur, wenn das Chat-Fenster nicht aktiv ist
  - zusammengefasst als „n neue Nachrichten“
  - Vorschau max. 120 Zeichen
- **Autostart** über `SMAppService.mainApp`.
- **Nur eine Instanz** läuft dank LSUIElement und Bundle-ID ohnehin. Ein erneuter Start bringt lediglich das Fenster nach vorn.

## Schritt 3: Build und Verteilung
- Neuer Workflow `.github/workflows/mac-client.yml` auf `macos-latest`:
  - `swift test` in `client-mac`
  - `xcodebuild -scheme ImgShareMac -configuration Release` mit **ad-hoc-Signatur** (`CODE_SIGN_IDENTITY=-`)
  - Ergebnis als `.zip` bzw. `.dmg` mit SHA-256-Prüfsumme, als Artefakt und bei Tags `v*` im Release (wie `windows-client.yml:73-97`)
- Die Standard-Serveradresse kommt aus `vars.IMGSHARE_DEFAULT_SERVER` und wird als Build-Setting in die Info.plist geschrieben.
- Im README kommt ein Abschnitt „macOS client“ dazu. Er erklärt den ersten Start: Rechtsklick → Öffnen bzw. Systemeinstellungen → Datenschutz & Sicherheit → „Trotzdem öffnen“, oder `xattr -dr com.apple.quarantine`.

## Verifikation
1. **Testvektoren:**
   - Mit dem C#-Core einmalig feste Vektoren erzeugen: festes `K`, daraus enc/room/token/safety, dazu ein Ciphertext mit fester Nonce und ein Base32-String.
   - Diese Vektoren als JSON unter `client-mac/Tests/…/vectors.json` ablegen.
   - XCTest-Tests prüfen das Swift-Ergebnis byte-genau dagegen.
   - Zusätzlich Tests für Base32-Grenzfälle (`0`/`1`, Restbits) und die Little-Endian-Behandlung beim Sicherheitscode.
2. **API gegen den echten Server:**
   - Den Go-Server lokal starten (`go run .` bzw. docker compose).
   - Ein Integrationstest in Swift deckt ab: Raum mit Invite anlegen, Text senden, PNG-Blob hochladen und laden, WebSocket-Presence, `401` bei falschem Token.
3. **Interop Mac ↔ Windows:**
   - Gegenüber spielen mit `client/ImgShare.SelfTest` im Modus `say` (siehe `Program.cs:8-40`, läuft mit .NET auf dem Mac).
   - Prüfen, dass der Mac-Client die Nachricht empfängt, entschlüsselt und eine Lesebestätigung zurückschickt.
   - Und umgekehrt: Was der Mac-Client sendet, muss der C#-Client lesen.
4. **Manuell in der App:**
   - Setup mit dem Schlüssel aus dem Windows-Client; der Sicherheitscode muss auf beiden Seiten identisch sein.
   - Bild per ⌘V und per Drag & Drop senden, Mitteilung bei inaktivem Fenster, Autostart, Ungelesen-Badge.
   - Neustart: Der Key muss aus dem Keychain geladen werden.

## Kritische Referenzdateien
- `docs/PROTOCOL.md`
- `client/ImgShare.Core/Crypto.cs`, `ApiClient.cs`, `ChatSession.cs`, `Models.cs`, `ImageFormat.cs`, `AppConfig.cs`, `ErrorText.cs`
- `client/ImgShare/Tray/TrayController.cs`, `Ui/SetupWindow.xaml.cs`, `Ui/ChatWindow.xaml.cs`, `App.xaml.cs`
- `client/ImgShare.SelfTest/Program.cs`, `internal/server/server_test.go`
- `.github/workflows/windows-client.yml`
