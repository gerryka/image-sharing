# ImgShare

Ende-zu-Ende-verschlüsselter Bild- und Text-Chat zwischen zwei Kollegen:
ein Windows-Programm im Infobereich und ein kleiner Go-Relay-Server (docker-compose).
Der Server speichert nur verschlüsselte Daten; alle Kryptografie läuft in den Clients.

Überblick über Architektur und Verschlüsselung: [docs/ImgShare-Architektur.pdf](docs/ImgShare-Architektur.pdf),
Spezifikation (Krypto, API, Datenbank, Limits): [docs/PROTOCOL.md](docs/PROTOCOL.md).

| Ordner / Datei | Inhalt |
|---|---|
| `main.go`, `internal/` | Go-Server |
| `Dockerfile`, `docker-compose.yml` | Container für den Server |
| `client/ImgShare` | Windows-Client (.NET 10, WPF) |
| `client/ImgShare.Core` | Krypto, API, Chat-Logik (ohne UI) |
| `client/ImgShare.SelfTest` | Ende-zu-Ende-Test gegen einen Server |
| `tools/MockServer` | Mock-Server für lokale Tests |
| `.github/workflows` | automatischer Build des Windows-Clients |

---

## Server

### Entwicklung

```sh
go test -race ./...
```

### Deployment

Das Projekt liegt am Server unter `/compose/image-sharing/`.

```sh
rsync -av -e "ssh -p <SSH-PORT>" --exclude data/ --exclude .env ./ root@server.example.com:/compose/image-sharing/
ssh -p <SSH-PORT> root@server.example.com 'cd /compose/image-sharing && docker compose up -d --build'
```

`./data` (SQLite + Blobs) muss dem Container-User `65532` gehören:
`mkdir -p data && chown 65532:65532 data`.

`./.env` (Rechte 600, nicht im Repo) enthält die Domain des Let's-Encrypt-Zertifikats
und den Zugangscode für neue Chats:

```sh
umask 077
echo "TLS_DOMAIN=server.example.com" > .env
echo "ROOM_CREATE_SECRET=$(openssl rand -hex 16)" >> .env
```

Ohne `.env` startet `docker compose` nicht. Weitere Limits und Variablen: siehe `docs/PROTOCOL.md`.

Healthcheck: `curl https://server.example.com:47000/healthz` → `ok`.

---

## Windows-Client

### Bauen

```
cd client/ImgShare
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DefaultServer=https://server.example.com:47000 -o ../../dist
```

Ergebnis: `dist/ImgShare.exe` – eine Datei, keine Installation, kein .NET nötig.
`DefaultServer` ist die vorbelegte Server-Adresse; ohne Angabe startet das Feld leer mit `https://`.

### Automatischer Build (GitHub Actions)

`.github/workflows/windows-client.yml` baut `ImgShare.exe` bei jedem Push auf `main`
(als Artefakt im Actions-Tab) und legt bei einem Tag `v*` ein Release mit EXE und
SHA-256-Prüfsumme an. Die Versionsnummer der EXE kommt aus dem Tag:

```
git tag v1.0.0
git push origin v1.0.0
```

Die vorbelegte Server-Adresse kommt dort aus der Repo-Variable `IMGSHARE_DEFAULT_SERVER`
(Settings → Secrets and variables → Actions → Variables).

### Einrichten

1. Einer startet `ImgShare.exe`, trägt Server, seinen Namen, den Chat-Namen und den
   **Server-Zugangscode** (`ROOM_CREATE_SECRET`) ein und lässt einen Schlüssel erzeugen.
2. Schlüssel **persönlich oder telefonisch** weitergeben (nicht per Mail/Chat), z. B. als QR-Code.
3. Der Kollege wählt „Einfügen“ und gibt den Schlüssel ein – er braucht keinen Zugangscode.
4. Beide vergleichen den **Sicherheitscode** – stimmt er überein, ist alles richtig.

### Bedienung

Enter sendet, Shift+Enter = neue Zeile, Strg+V fügt Bilder ein (auch Screenshots),
Drag & Drop von PNG/JPG, Strg+F sucht im Verlauf, Esc schließt das Fenster in den
Infobereich. Rechtsklick auf eine Nachricht: Kopieren / Speichern / Erneut senden.

Lokal gespeichert: `%APPDATA%\ImgShare\config.json` (Schlüssel per Windows DPAPI
geschützt) und `%LOCALAPPDATA%\ImgShare\cache` (Bilder, verschlüsselt).

### Lokal testen ohne echten Server

```
dotnet run --project tools/MockServer -- --urls http://localhost:47001
dotnet run --project client/ImgShare.SelfTest -- http://localhost:47001
```

Gegen einen echten Server: `dotnet run --project client/ImgShare.SelfTest -- <server> <zugangscode>`.

Zwei Client-Instanzen auf einem Rechner: Umgebungsvariable `IMGSHARE_HOME`
auf je einen eigenen Ordner setzen.
