# ImgShare

End-to-end encrypted image and text chat between two people:
a small Windows tray app and a lightweight Go relay server (docker-compose).
The server only ever stores encrypted data; all cryptography happens in the clients.

Architecture and encryption overview (German): [docs/ImgShare-Architektur.pdf](docs/ImgShare-Architektur.pdf).
Specification (crypto, API, database, limits; German): [docs/PROTOCOL.md](docs/PROTOCOL.md).
The client UI is currently in German.

| Folder / file | Contents |
|---|---|
| `main.go`, `internal/` | Go server |
| `Dockerfile`, `docker-compose.yml` | Server container |
| `client/ImgShare` | Windows client (.NET 10, WPF) |
| `client/ImgShare.Core` | Crypto, API and chat logic (no UI) |
| `client/ImgShare.SelfTest` | End-to-end test against a server |
| `tools/MockServer` | Mock server for local testing |
| `.github/workflows` | Automated build of the Windows client |

---

## Server

### Development

```sh
go test -race ./...
```

### Deployment

On the server, the project lives in `/compose/image-sharing/`.

```sh
rsync -av -e "ssh -p <SSH-PORT>" --exclude data/ --exclude .env ./ root@server.example.com:/compose/image-sharing/
ssh -p <SSH-PORT> root@server.example.com 'cd /compose/image-sharing && docker compose up -d --build'
```

`./data` (SQLite + blobs) must be owned by the container user `65532`:
`mkdir -p data && chown 65532:65532 data`.

`./.env` (mode 600, not in the repo) holds the domain of the Let's Encrypt certificate
and the invite code required to create new chats:

```sh
umask 077
echo "TLS_DOMAIN=server.example.com" > .env
echo "ROOM_CREATE_SECRET=$(openssl rand -hex 16)" >> .env
```

`docker compose` refuses to start without `.env`. Further limits and variables: see `docs/PROTOCOL.md`.

Health check: `curl https://server.example.com:47000/healthz` → `ok`.

---

## Windows client

### Build

```
cd client/ImgShare
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DefaultServer=https://server.example.com:47000 -o ../../dist
```

Result: `dist/ImgShare.exe` – a single file, no installation, no .NET required.
`DefaultServer` pre-fills the server address; without it the field starts as `https://`.

For the small variant, use `--self-contained false` instead of `--self-contained true`,
drop the `…SelfExtract` / `…Compression` switches and publish into an empty output folder.

### Automated build (GitHub Actions)

`.github/workflows/windows-client.yml` builds two variants on every push to `main`
(available as artifacts in the Actions tab):

| File | Size | Requirement |
|---|---|---|
| `ImgShare.exe` | ~73 MB | none – bundles the .NET runtime |
| `ImgShare-fx.exe` | ~0.5 MB | [.NET 10 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/10.0) (x64) |

Pushing a tag `v*` additionally creates a GitHub release with both EXEs and SHA-256
checksums. The version number of the EXEs is taken from the tag:

```
git tag v1.0.0
git push origin v1.0.0
```

The pre-filled server address comes from the repository variable `IMGSHARE_DEFAULT_SERVER`
(Settings → Secrets and variables → Actions → Variables).

### Setting up a chat

1. One person starts `ImgShare.exe`, enters the server, their name, a chat name and the
   **server invite code** (`ROOM_CREATE_SECRET`), and lets the app generate a key.
2. Share the key **in person or by phone** (not by email or chat), e.g. as a QR code.
3. The other person chooses “Einfügen” (paste) and enters the key – no invite code needed.
4. Both compare the **safety code** – if it matches, everything is set up correctly.

### Usage

Enter sends, Shift+Enter inserts a new line, Ctrl+V pastes images (including screenshots),
drag & drop works for PNG/JPG, Ctrl+F searches the history, Esc hides the window to the
tray. Right-click a message to copy, save or resend it.

Stored locally: `%APPDATA%\ImgShare\config.json` (key protected with Windows DPAPI)
and `%LOCALAPPDATA%\ImgShare\cache` (images, still encrypted).

### Testing locally without a real server

```
dotnet run --project tools/MockServer -- --urls http://localhost:47001
dotnet run --project client/ImgShare.SelfTest -- http://localhost:47001
```

Against a real server: `dotnet run --project client/ImgShare.SelfTest -- <server> <invite-code>`.

To run two client instances on one machine, set the environment variable `IMGSHARE_HOME`
to a separate folder for each.
