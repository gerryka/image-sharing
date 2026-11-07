// Minimaler Mock des Servers nach docs/PROTOCOL.md – nur für lokale Tests des Windows-Clients.
// In-Memory, ohne TLS. Start: dotnet run --project tools/MockServer -- --urls http://localhost:47001
// Der echte Server ist das Go-Projekt (am Mac gebaut).
using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.SetMinimumLevel(LogLevel.Warning);
builder.WebHost.ConfigureKestrel(o => o.Limits.MaxRequestBodySize = 26214400);
var app = builder.Build();
app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(30) });

var rooms = new ConcurrentDictionary<string, Room>();
long nextId = 0;
var roomRx = new Regex("^[0-9a-f]{32}$");

Room? Auth(HttpContext ctx, string roomId)
{
    if (!roomRx.IsMatch(roomId)) { ctx.Response.StatusCode = 400; return null; }
    var h = ctx.Request.Headers.Authorization.ToString();
    if (!h.StartsWith("Bearer ")) { ctx.Response.StatusCode = 401; return null; }
    var hash = SHA256.HashData(Encoding.ASCII.GetBytes(h[7..]));
    var room = rooms.GetOrAdd(roomId, _ => new Room(hash));   // trust on first use
    if (!CryptographicOperations.FixedTimeEquals(room.TokenHash, hash)) { ctx.Response.StatusCode = 401; return null; }
    return room;
}

IResult Err(int status, string code) => Results.Json(new { error = code }, statusCode: status);

app.MapGet("/healthz", () => "ok");

app.MapPost("/v1/rooms/{room}/messages", async (HttpContext ctx, string room) =>
{
    var r = Auth(ctx, room); if (r is null) return Err(ctx.Response.StatusCode, "unauthorized");
    var body = await JsonSerializer.DeserializeAsync<JsonElement>(ctx.Request.Body);
    var ct = body.GetProperty("ciphertext").GetString()!;
    var msg = new Msg(Interlocked.Increment(ref nextId), DateTimeOffset.UtcNow, ct);
    lock (r) r.Messages.Add(msg);
    await r.Broadcast(new { type = "message", id = msg.Id, server_ts = msg.Ts, ciphertext = msg.Ct });
    return Results.Json(new { id = msg.Id, server_ts = msg.Ts }, statusCode: 201);
});

app.MapGet("/v1/rooms/{room}/messages", (HttpContext ctx, string room, long? after, long? before, int? limit) =>
{
    var r = Auth(ctx, room); if (r is null) return Err(ctx.Response.StatusCode, "unauthorized");
    int n = Math.Clamp(limit ?? 100, 1, 500);
    List<Msg> sel; bool more;
    lock (r)
    {
        if (before is { } b)
        {
            var older = r.Messages.Where(m => m.Id < b).ToList();
            sel = older.TakeLast(n).ToList(); more = older.Count > n;
        }
        else
        {
            var newer = r.Messages.Where(m => m.Id > (after ?? 0)).ToList();
            sel = newer.Take(n).ToList(); more = newer.Count > n;
        }
    }
    return Results.Json(new
    {
        messages = sel.Select(m => new { id = m.Id, server_ts = m.Ts, ciphertext = m.Ct }),
        has_more = more
    });
});

app.MapPost("/v1/rooms/{room}/blobs", async (HttpContext ctx, string room) =>
{
    var r = Auth(ctx, room); if (r is null) return Err(ctx.Response.StatusCode, "unauthorized");
    using var ms = new MemoryStream();
    await ctx.Request.Body.CopyToAsync(ms);
    var id = Guid.NewGuid().ToString();
    r.Blobs[id] = ms.ToArray();
    return Results.Json(new { blob_id = id, size = ms.Length }, statusCode: 201);
});

app.MapGet("/v1/rooms/{room}/blobs/{id}", (HttpContext ctx, string room, string id) =>
{
    var r = Auth(ctx, room); if (r is null) return Err(ctx.Response.StatusCode, "unauthorized");
    return r.Blobs.TryGetValue(id, out var data)
        ? Results.Bytes(data, "application/octet-stream")
        : Err(404, "not_found");
});

app.Map("/v1/rooms/{room}/ws", async (HttpContext ctx, string room) =>
{
    var r = Auth(ctx, room); if (r is null) return;
    if (!ctx.WebSockets.IsWebSocketRequest) { ctx.Response.StatusCode = 400; return; }
    using var ws = await ctx.WebSockets.AcceptWebSocketAsync();
    r.Sockets[ws] = 0;
    await r.Broadcast(new { type = "presence", online = r.Sockets.Count });
    var buf = new byte[1024];
    try { while (ws.State == WebSocketState.Open) { var res = await ws.ReceiveAsync(buf, default); if (res.MessageType == WebSocketMessageType.Close) break; } }
    catch { }
    r.Sockets.TryRemove(ws, out _);
    await r.Broadcast(new { type = "presence", online = r.Sockets.Count });
});

// Debug: zeigt, was der Server tatsächlich sieht
app.MapGet("/debug/dump", () => rooms.Select(kv => new
{
    room = kv.Key,
    messages = kv.Value.Messages.Select(m => new { m.Id, m.Ts, ciphertext_prefix = m.Ct[..Math.Min(40, m.Ct.Length)] }),
    blobs = kv.Value.Blobs.Select(b => new { id = b.Key, size = b.Value.Length })
}));

app.Run();

record Msg(long Id, DateTimeOffset Ts, string Ct);

sealed class Room(byte[] tokenHash)
{
    public byte[] TokenHash { get; } = tokenHash;
    public List<Msg> Messages { get; } = new();
    public ConcurrentDictionary<string, byte[]> Blobs { get; } = new();
    public ConcurrentDictionary<WebSocket, byte> Sockets { get; } = new();

    public async Task Broadcast(object frame)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(frame);
        foreach (var ws in Sockets.Keys)
        {
            try { await ws.SendAsync(bytes, WebSocketMessageType.Text, true, default); } catch { }
        }
    }
}
