using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.WebSockets;
using System.Text.Json;

namespace ImgShare.Core;

public sealed class ApiException : Exception
{
    public HttpStatusCode Status { get; }
    public string? Code { get; }

    public ApiException(HttpStatusCode status, string? code)
        : base(Describe(status, code)) { Status = status; Code = code; }

    static string Describe(HttpStatusCode s, string? code) => (s, code) switch
    {
        (HttpStatusCode.Unauthorized, _) => "Zugriff verweigert – passt der Schlüssel?",
        (HttpStatusCode.Forbidden, "invite_required") =>
            "Der Chat existiert auf dem Server noch nicht. Zum Anlegen braucht es den Server-Zugangscode.",
        (HttpStatusCode.RequestEntityTooLarge, _) => "Datei ist zu groß für den Server.",
        (HttpStatusCode.TooManyRequests, _) => "Zu viele Anfragen, bitte kurz warten.",
        (HttpStatusCode.InsufficientStorage, "quota_exceeded") => "Der Speicher für diesen Chat am Server ist voll.",
        (HttpStatusCode.InsufficientStorage, "room_limit") => "Auf dem Server können keine weiteren Chats angelegt werden.",
        (HttpStatusCode.InsufficientStorage, _) => "Der Server hat keinen freien Speicher mehr.",
        _ => $"Serverfehler {(int)s}{(code is null ? "" : $" ({code})")}"
    };
}

public sealed class ApiClient : IDisposable
{
    readonly HttpClient _http;
    readonly Uri _base;
    readonly string _room;
    readonly string _token;

    public const string InviteHeader = "X-Invite-Code";
    readonly string _invite;

    public ApiClient(string serverUrl, ChatKeys keys, string? invite = null)
    {
        _base = new Uri(serverUrl.TrimEnd('/') + "/");
        _room = keys.RoomId;
        _token = keys.TokenBase64Url;
        _invite = invite?.Trim() ?? "";
        _http = new HttpClient
        {
            BaseAddress = _base,
            Timeout = TimeSpan.FromMinutes(5),
            // Ein bösartiger Server soll den Client nicht per Riesenantwort lahmlegen (Blob max. 25 MB).
            MaxResponseContentBufferSize = 32L * 1024 * 1024,
        };
        _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", _token);
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("ImgShare/1.0");
        // Nur beim allerersten Anlegen eines Chats nötig; der Server ignoriert ihn sonst.
        if (_invite.Length > 0) _http.DefaultRequestHeaders.Add(InviteHeader, _invite);
    }

    /// <summary>https ist Pflicht, http nur für localhost (Tests).</summary>
    public static bool IsAllowedServerUrl(string url, out string? error)
    {
        error = null;
        if (!Uri.TryCreate(url.Trim(), UriKind.Absolute, out var u)) { error = "Ungültige Server-Adresse."; return false; }
        if (u.Scheme == Uri.UriSchemeHttps) return true;
        if (u.Scheme == Uri.UriSchemeHttp && u.IsLoopback) return true;
        error = "Die Server-Adresse muss mit https:// beginnen.";
        return false;
    }

    string P(string rel) => $"v1/rooms/{_room}/{rel}";

    static async Task EnsureOk(HttpResponseMessage res, CancellationToken ct)
    {
        if (res.IsSuccessStatusCode) return;
        string? code = null;
        try
        {
            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
            code = doc.RootElement.GetProperty("error").GetString();
        }
        catch { /* kein JSON */ }
        throw new ApiException(res.StatusCode, code);
    }

    public async Task<PostMessageResult> PostMessageAsync(byte[] ciphertext, CancellationToken ct = default)
    {
        using var res = await _http.PostAsJsonAsync(P("messages"),
            new { ciphertext = Convert.ToBase64String(ciphertext) }, ct);
        await EnsureOk(res, ct);
        return (await res.Content.ReadFromJsonAsync<PostMessageResult>(ct))!;
    }

    public async Task<MessagesPage> GetMessagesAsync(long? after = null, long? before = null, int limit = 100,
        CancellationToken ct = default)
    {
        var q = new List<string> { $"limit={limit}" };
        if (after is { } a) q.Add($"after={a}");
        if (before is { } b) q.Add($"before={b}");
        using var res = await _http.GetAsync(P("messages") + "?" + string.Join("&", q), ct);
        await EnsureOk(res, ct);
        return (await res.Content.ReadFromJsonAsync<MessagesPage>(ct)) ?? new MessagesPage();
    }

    public async Task<BlobResult> UploadBlobAsync(byte[] data, IProgress<double>? progress, CancellationToken ct = default)
    {
        using var content = new ProgressContent(data, progress);
        using var res = await _http.PostAsync(P("blobs"), content, ct);
        await EnsureOk(res, ct);
        return (await res.Content.ReadFromJsonAsync<BlobResult>(ct))!;
    }

    public async Task<byte[]> GetBlobAsync(string blobId, CancellationToken ct = default)
    {
        using var res = await _http.GetAsync(P("blobs/" + Uri.EscapeDataString(blobId)), ct);
        await EnsureOk(res, ct);
        return await res.Content.ReadAsByteArrayAsync(ct);
    }

    public async Task<ClientWebSocket> ConnectWebSocketAsync(CancellationToken ct)
    {
        var b = new UriBuilder(new Uri(_base, P("ws")));
        b.Scheme = b.Scheme == "https" ? "wss" : "ws";
        var ws = new ClientWebSocket();
        ws.Options.SetRequestHeader("Authorization", "Bearer " + _token);
        if (_invite.Length > 0) ws.Options.SetRequestHeader(InviteHeader, _invite);
        ws.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
        try
        {
            await ws.ConnectAsync(b.Uri, ct);
            return ws;
        }
        catch
        {
            ws.Dispose();
            throw;
        }
    }

    public void Dispose() => _http.Dispose();

    sealed class ProgressContent : HttpContent
    {
        readonly byte[] _data;
        readonly IProgress<double>? _progress;

        public ProgressContent(byte[] data, IProgress<double>? progress)
        {
            _data = data; _progress = progress;
            Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        }

        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
        {
            const int chunk = 64 * 1024;
            for (int off = 0; off < _data.Length; off += chunk)
            {
                int len = Math.Min(chunk, _data.Length - off);
                await stream.WriteAsync(_data.AsMemory(off, len));
                _progress?.Report((double)(off + len) / _data.Length);
            }
        }

        protected override bool TryComputeLength(out long length) { length = _data.Length; return true; }
    }
}
