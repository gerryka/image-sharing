# Bildsharing

Ende-zu-Ende-verschlüsselter Bild- und Text-Chat zwischen zwei Kollegen.
Windows-Systray-Client + kleiner Go-Server (docker-compose).

| Ordner | Inhalt |
|---|---|
| `docs/PROTOCOL.md` | Spezifikation: Krypto, API, Datenbank, Betrieb |
| `client/ImgShare` | Windows-Client (.NET 10, WPF) |
| `client/ImgShare.Core` | Krypto, API, Chat-Logik (ohne UI) |
| `client/ImgShare.SelfTest` | End-to-End-Test gegen einen Server |
| `tools/MockServer` | Mock-Server für lokale Tests |
| `server/` | Go-Server (wird am Mac gebaut) |

## Windows-Client bauen

```
cd client/ImgShare
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o ../../dist
```

Ergebnis: `dist/ImgShare.exe` – eine Datei, keine Installation, kein .NET nötig.

## Einrichten

1. Einer startet `ImgShare.exe`, trägt Server (z. B. `https://server.example.com:47000`),
   seinen Namen und den Chat-Namen ein und lässt einen Schlüssel erzeugen.
2. Schlüssel **persönlich oder telefonisch** weitergeben (nicht per Mail/Chat).
3. Der Kollege wählt „Einfügen“ und gibt den Schlüssel ein.
4. Beide vergleichen den **Sicherheitscode** – stimmt er überein, ist alles richtig.

Bedienung: Enter sendet, Shift+Enter = neue Zeile, Strg+V fügt Bilder ein
(auch Screenshots), Drag & Drop von PNG/JPG, Strg+F sucht im Verlauf,
Esc schließt das Fenster in den Infobereich. Rechtsklick auf eine Nachricht:
Kopieren / Speichern / Erneut senden.

Lokal gespeichert: `%APPDATA%\ImgShare\config.json` (Schlüssel per Windows
DPAPI geschützt) und `%LOCALAPPDATA%\ImgShare\cache` (Bilder, verschlüsselt).

## Lokal testen ohne echten Server

```
dotnet run --project tools/MockServer -- --urls http://localhost:47001
dotnet run --project client/ImgShare.SelfTest -- http://localhost:47001
```

Zwei Client-Instanzen auf einem Rechner: Umgebungsvariable `IMGSHARE_HOME`
auf je einen eigenen Ordner setzen.

## Automatischer Build (GitHub Actions)

`.github/workflows/windows-client.yml` baut `ImgShare.exe` bei jedem Push auf `main`
(als Artefakt im Actions-Tab) und legt bei einem Tag `v*` ein Release mit EXE und
SHA-256-Prüfsumme an:

```
git tag v1.0.0
git push origin v1.0.0
```

Die Versionsnummer der EXE kommt aus dem Tag.

Die vorbelegte Server-Adresse steht nicht im Code. In der CI kommt sie aus der
Repo-Variable `IMGSHARE_DEFAULT_SERVER` (Settings → Secrets and variables → Actions →
Variables), lokal aus `-p:DefaultServer=https://…` beim `dotnet publish`.
Ohne Angabe startet das Feld leer mit `https://`.
