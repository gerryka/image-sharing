using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ImgShare.Core;

/// <summary>
/// Eine Chat-Verbindung: hält den entschlüsselten Verlauf, die WebSocket-Verbindung
/// und sendet Text, Bilder und Lesebestätigungen.
/// Wird sie vom UI-Thread gestartet, laufen alle Events auf dem UI-Thread.
/// </summary>
public sealed class ChatSession : IDisposable
{
    static readonly Regex SafeBlobId = new("^[A-Za-z0-9-]{1,64}$", RegexOptions.Compiled);

    readonly Action _saveConfig;
    readonly ApiClient _api;
    readonly CancellationTokenSource _cts = new();
    readonly object _gate = new();
    readonly SortedList<long, ChatMessage> _messages = new();
    readonly HashSet<long> _seen = new();
    bool _initialLoaded;
    long _minSeenId = long.MaxValue;
    long _maxSeenId;
    long _myReadUpTo;

    public ChatEntry Entry { get; }
    public ChatKeys Keys { get; }

    public ConnectionState State { get; private set; } = ConnectionState.Connecting;
    public bool OtherOnline { get; private set; }
    public long OtherReadUpTo { get; private set; }
    public bool HasOlder { get; private set; } = true;
    /// <summary>true, sobald der Verlauf einmal vom Server geladen wurde.</summary>
    public bool IsLoaded => _initialLoaded;
    public string? LastError { get; private set; }

    /// <summary>Neue Nachricht im Verlauf (auch eigene). isLive = kam nach dem ersten Laden.</summary>
    public event Action<ChatMessage, bool>? MessageAdded;
    /// <summary>Verlauf wurde initial geladen oder ältere Nachrichten wurden vorne eingefügt.</summary>
    public event Action? HistoryChanged;
    public event Action? ReadStateChanged;
    public event Action? ConnectionChanged;
    public event Action? UnreadChanged;

    public ChatSession(ChatEntry entry, Action saveConfig)
    {
        Entry = entry;
        _saveConfig = saveConfig;
        Keys = ChatKeys.Derive(entry.GetRootKey());
        _api = new ApiClient(entry.ServerUrl, Keys, entry.GetInvite());
    }

    public IReadOnlyList<ChatMessage> Messages
    {
        get { lock (_gate) return _messages.Values.ToList(); }
    }

    public int UnreadCount
    {
        get { lock (_gate) return _messages.Values.Count(m => !m.IsMine && m.Id > Entry.LastReadId); }
    }

    // ------------------------------------------------------------------ Verbindung

    public async Task RunAsync()
    {
        var ct = _cts.Token;
        var delay = TimeSpan.FromSeconds(1);
        while (!ct.IsCancellationRequested)
        {
            try
            {
                SetState(ConnectionState.Connecting);
                await CatchUpAsync(ct);                       // Verlauf auch ohne WebSocket
                using var ws = await _api.ConnectWebSocketAsync(ct);
                await CatchUpAsync(ct);                       // Lücke zwischen GET und WS schließen
                LastError = null;
                SetState(ConnectionState.Online);
                delay = TimeSpan.FromSeconds(1);
                await ReceiveLoopAsync(ws, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            catch (Exception ex) { LastError = ErrorText.Describe(ex); }

            OtherOnline = false;
            SetState(ConnectionState.Offline);
            try { await Task.Delay(delay, ct); } catch (OperationCanceledException) { break; }
            delay = TimeSpan.FromSeconds(Math.Min(delay.TotalSeconds * 2, 30));
        }
    }

    async Task CatchUpAsync(CancellationToken ct)
    {
        if (!_initialLoaded)
        {
            var page = await _api.GetMessagesAsync(before: long.MaxValue, limit: 200, ct: ct);
            foreach (var em in page.Messages) Process(em, live: false);
            HasOlder = page.HasMore;
            _initialLoaded = true;
            HistoryChanged?.Invoke();
            UnreadChanged?.Invoke();
            return;
        }
        while (true)
        {
            var page = await _api.GetMessagesAsync(after: _maxSeenId, limit: 500, ct: ct);
            foreach (var em in page.Messages) Process(em, live: true);
            if (!page.HasMore || page.Messages.Count == 0) break;
        }
    }

    async Task ReceiveLoopAsync(ClientWebSocket ws, CancellationToken ct)
    {
        var buffer = new byte[16 * 1024];
        using var ms = new MemoryStream();
        while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
        {
            ms.SetLength(0);
            WebSocketReceiveResult r;
            do
            {
                r = await ws.ReceiveAsync(buffer, ct);
                if (r.MessageType == WebSocketMessageType.Close) return;
                ms.Write(buffer, 0, r.Count);
                if (ms.Length > 4 * 1024 * 1024) throw new InvalidDataException("WebSocket-Nachricht zu groß.");
            } while (!r.EndOfMessage);

            HandleWsFrame(ms.ToArray());
        }
    }

    void HandleWsFrame(byte[] frame)
    {
        try
        {
            using var doc = JsonDocument.Parse(frame);
            var root = doc.RootElement;
            switch (root.GetProperty("type").GetString())
            {
                case "message":
                    var em = root.Deserialize<EncryptedMessage>();
                    if (em is not null) Process(em, live: true);
                    break;
                case "presence":
                    var online = root.GetProperty("online").GetInt32() >= 2;
                    if (online != OtherOnline) { OtherOnline = online; ConnectionChanged?.Invoke(); }
                    break;
            }
        }
        catch (JsonException) { /* unbekanntes Frame ignorieren */ }
    }

    void SetState(ConnectionState s)
    {
        if (State == s) return;
        State = s;
        ConnectionChanged?.Invoke();
    }

    // ------------------------------------------------------------------ Verarbeitung

    /// <returns>true, wenn eine neue sichtbare Nachricht hinzugekommen ist.</returns>
    bool Process(EncryptedMessage em, bool live, bool raiseAdded = true)
    {
        ChatMessage? added = null;
        bool readChanged = false;
        lock (_gate)
        {
            if (!_seen.Add(em.Id)) return false;
            _minSeenId = Math.Min(_minSeenId, em.Id);
            _maxSeenId = Math.Max(_maxSeenId, em.Id);

            Payload? p;
            try
            {
                var plain = Keys.Decrypt(Convert.FromBase64String(em.Ciphertext));
                p = JsonSerializer.Deserialize<Payload>(plain);
            }
            catch { return false; } // nicht entschlüsselbar → ignorieren
            if (p is null) return false;

            bool mine = p.Sender == Entry.DeviceId;
            switch (p.Kind)
            {
                case MessageKind.Read:
                    var upTo = p.ReadUpTo ?? 0;
                    if (mine) _myReadUpTo = Math.Max(_myReadUpTo, upTo);
                    else if (upTo > OtherReadUpTo) { OtherReadUpTo = upTo; readChanged = true; }
                    break;
                case MessageKind.Text when !string.IsNullOrEmpty(p.Text):
                case MessageKind.Image when p.Image is not null && SafeBlobId.IsMatch(p.Image.BlobId):
                    added = new ChatMessage { Id = em.Id, ServerTs = em.ServerTs, Payload = p, IsMine = mine };
                    _messages[em.Id] = added;
                    break;
            }
        }

        if (readChanged) ReadStateChanged?.Invoke();
        if (added is null) return false;
        if (_initialLoaded && raiseAdded) MessageAdded?.Invoke(added, live);
        if (!added.IsMine) UnreadChanged?.Invoke();
        return true;
    }

    public async Task LoadOlderAsync()
    {
        if (!HasOlder || !_initialLoaded) return;
        var page = await _api.GetMessagesAsync(before: _minSeenId, limit: 100);
        bool any = false;
        foreach (var em in page.Messages)
        {
            lock (_gate) { if (_seen.Contains(em.Id)) continue; }
            // ältere Nachrichten ohne MessageAdded-Event einsortieren
            any |= Process(em, live: false, raiseAdded: false);
        }
        HasOlder = page.HasMore && page.Messages.Count > 0;
        if (any || !HasOlder) HistoryChanged?.Invoke();
    }

    // ------------------------------------------------------------------ Senden

    Payload NewPayload(string kind) => new()
    {
        Kind = kind,
        Sender = Entry.DeviceId,
        SenderName = Entry.MyName,
        SentAt = DateTimeOffset.UtcNow
    };

    async Task<long> PostAsync(Payload p)
    {
        var ciphertext = Keys.Encrypt(JsonSerializer.SerializeToUtf8Bytes(p));
        var res = await _api.PostMessageAsync(ciphertext);
        // Server pusht die Nachricht auch per WebSocket zurück; Process dedupliziert über die ID.
        Process(new EncryptedMessage
        {
            Id = res.Id, ServerTs = res.ServerTs, Ciphertext = Convert.ToBase64String(ciphertext)
        }, live: true);
        return res.Id;
    }

    public Task<long> SendTextAsync(string text)
    {
        var p = NewPayload(MessageKind.Text);
        p.Text = text;
        return PostAsync(p);
    }

    public async Task<long> SendImageAsync(byte[] image, string fileName, int width, int height,
        IProgress<double>? progress = null)
    {
        var mime = ImageFormat.DetectMime(image) ?? throw new InvalidDataException("Nur PNG und JPG werden unterstützt.");
        if (image.Length > ImageFormat.MaxImageBytes) throw new InvalidDataException("Bild ist größer als 24 MB.");

        var blob = Keys.Encrypt(image);
        var up = await _api.UploadBlobAsync(blob, progress);
        WriteCache(up.BlobId, blob);

        var p = NewPayload(MessageKind.Image);
        p.Image = new ImageInfo
        {
            BlobId = up.BlobId, Mime = mime, FileName = fileName,
            Size = image.Length, Width = width, Height = height
        };
        return await PostAsync(p);
    }

    /// <summary>Lokal als gelesen markieren und ggf. Lesebestätigung senden.</summary>
    public async Task MarkReadAsync()
    {
        long latest;
        lock (_gate)
            latest = _messages.Values.Where(m => !m.IsMine).Select(m => m.Id).DefaultIfEmpty(0).Max();
        if (latest > Entry.LastReadId)
        {
            Entry.LastReadId = latest;
            _saveConfig();
            UnreadChanged?.Invoke();
        }
        if (latest > _myReadUpTo)
        {
            _myReadUpTo = latest;
            var p = NewPayload(MessageKind.Read);
            p.ReadUpTo = latest;
            try { await PostAsync(p); } catch { _myReadUpTo = 0; }
        }
    }

    // ------------------------------------------------------------------ Bilder

    string CachePath(string blobId) => Path.Combine(AppConfig.CacheDir, Keys.RoomId, blobId);

    void WriteCache(string blobId, byte[] encrypted)
    {
        try
        {
            var path = CachePath(blobId);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllBytes(path, encrypted); // Cache bleibt verschlüsselt
        }
        catch { /* Cache ist optional */ }
    }

    /// <summary>Lädt (oder liest aus dem verschlüsselten Cache) und entschlüsselt ein Bild.</summary>
    public async Task<byte[]> GetImageBytesAsync(ImageInfo info)
    {
        if (!SafeBlobId.IsMatch(info.BlobId)) throw new InvalidDataException("Ungültige Bild-ID.");
        var path = CachePath(info.BlobId);
        if (File.Exists(path))
        {
            try { return DecryptImage(await File.ReadAllBytesAsync(path)); }
            catch
            {
                // Kaputter Cache-Eintrag: verwerfen und neu laden.
                try { File.Delete(path); } catch { }
            }
        }
        var enc = await _api.GetBlobAsync(info.BlobId);
        var plain = DecryptImage(enc);      // erst prüfen …
        WriteCache(info.BlobId, enc);       // … dann cachen
        return plain;
    }

    byte[] DecryptImage(byte[] enc)
    {
        var plain = Keys.Decrypt(enc);
        if (ImageFormat.DetectMime(plain) is null) throw new InvalidDataException("Kein gültiges Bild.");
        return plain;
    }

    // ------------------------------------------------------------------ Test der Verbindung

    public static async Task TestConnectionAsync(string serverUrl, byte[] rootKey, string? invite = null)
    {
        using var api = new ApiClient(serverUrl, ChatKeys.Derive(rootKey), invite);
        await api.GetMessagesAsync(after: 0, limit: 1);
    }

    public void Dispose()
    {
        _cts.Cancel();
        _api.Dispose();
    }
}
