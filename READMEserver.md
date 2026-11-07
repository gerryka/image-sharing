# imgshare – Server

Relay-Server für Ende-zu-Ende-verschlüsseltes Bildsharing. Spezifikation: [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Entwicklung

```sh
go test -race ./...
```

## Deployment

Projekt liegt unter `/compose/image-sharing/`.

```sh
rsync -av -e "ssh -p <SSH-PORT>" --exclude data/ ./ root@server.example.com:/compose/image-sharing/
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

Ohne `.env` startet `docker compose` nicht. Limits und Variablen: siehe `docs/PROTOCOL.md`.

Healthcheck: `curl https://server.example.com:47000/healthz` → `ok`.
