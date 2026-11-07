// End-to-End-Selbsttest der Client-Logik gegen einen Server (Mock oder echt).
// Aufruf: dotnet run --project client/ImgShare.SelfTest -- http://localhost:47001
using System.Text;
using ImgShare.Core;

// Hilfsmodus für UI-Tests: Config für eine Test-Instanz anlegen
//   seed <home> <server> <meinName> <chatName> <key>
if (args.Length == 6 && args[0] == "seed")
{
    Environment.SetEnvironmentVariable("IMGSHARE_HOME", args[1]);
    if (!KeyFormat.TryParse(args[5], out var seedKey)) { Console.WriteLine("Key ungültig"); return 2; }
    var cfg = AppConfig.Load();
    var e = new ChatEntry { ServerUrl = args[2], MyName = args[3], ChatName = args[4] };
    e.SetRootKey(seedKey);
    cfg.Chats.Add(e);
    cfg.Save();
    Console.WriteLine($"Config in {AppConfig.ConfigDir} angelegt.");
    return 0;
}
// Hilfsmodus: als Kollege Nachrichten in einen Raum schreiben
//   say <server> <key> <name> <text|@bild.png>
if (args.Length == 5 && args[0] == "say")
{
    Environment.SetEnvironmentVariable("IMGSHARE_HOME", Path.Combine(Path.GetTempPath(), "imgshare-say"));
    KeyFormat.TryParse(args[2], out var sayKey);
    var e = new ChatEntry { ServerUrl = args[1], MyName = args[3], ChatName = "x", DeviceId = "say-" + args[3] };
    e.SetRootKey(sayKey);
    using var s = new ChatSession(e, () => { });
    if (args[4].StartsWith('@'))
    {
        var img = File.ReadAllBytes(args[4][1..]);
        // PNG-Header: Breite/Höhe big-endian ab Byte 16
        int w = img.Length > 24 ? (img[16] << 24) | (img[17] << 16) | (img[18] << 8) | img[19] : 0;
        int h = img.Length > 24 ? (img[20] << 24) | (img[21] << 16) | (img[22] << 8) | img[23] : 0;
        await s.SendImageAsync(img, Path.GetFileName(args[4][1..]), w, h);
    }
    else await s.SendTextAsync(args[4]);
    Console.WriteLine("gesendet");
    return 0;
}

var server = args.Length > 0 ? args[0] : "http://localhost:47001";
var invite = args.Length > 1 ? args[1] : null; // Server-Zugangscode zum Anlegen des Testraums
int failures = 0;
void Check(bool ok, string what) { Console.WriteLine($"{(ok ? "OK  " : "FAIL")} {what}"); if (!ok) failures++; }

// --- Schlüsselformat
var root = ChatKeys.GenerateRootKey();
var text = KeyFormat.Format(root);
Check(KeyFormat.TryParse(text, out var parsed) && parsed.SequenceEqual(root), $"Key-Roundtrip ({text})");
Check(KeyFormat.TryParse(text.ToLowerInvariant().Replace("-", " "), out _), "Key tolerant gegen Klein/Leerzeichen");
Check(!KeyFormat.TryParse(text[..^2], out _), "Gekürzter Key wird abgelehnt");

var keys = ChatKeys.Derive(root);
Check(keys.RoomId.Length == 32, $"room_id {keys.RoomId}");
Check(keys.Decrypt(keys.Encrypt("hallo"u8)).SequenceEqual("hallo"u8.ToArray()), "AES-GCM Roundtrip");
var other = ChatKeys.Derive(ChatKeys.GenerateRootKey());
Check(Throws(() => other.Decrypt(keys.Encrypt("x"u8))), "Fremder Key kann nicht entschlüsseln");

// --- Zwei Clients im selben Raum
ChatEntry Entry(string name) { var e = new ChatEntry { ServerUrl = server, MyName = name, ChatName = "Test" }; e.SetRootKey(root); e.SetInvite(invite); return e; }
var a = new ChatSession(Entry("Georg"), () => { });
var b = new ChatSession(Entry("Lukas"), () => { });
var gotB = new TaskCompletionSource<ChatMessage>();
var gotImg = new TaskCompletionSource<ChatMessage>();
b.MessageAdded += (m, live) => { if (!m.IsMine && m.Kind == MessageKind.Text) gotB.TrySetResult(m); if (!m.IsMine && m.Kind == MessageKind.Image) gotImg.TrySetResult(m); };
var readA = new TaskCompletionSource();
a.ReadStateChanged += () => readA.TrySetResult();

_ = a.RunAsync(); _ = b.RunAsync();
await WaitUntil(() => a.State == ConnectionState.Online && b.State == ConnectionState.Online, "beide online");
await WaitUntil(() => a.OtherOnline && b.OtherOnline, "Presence: Gegenüber online");

var id = await a.SendTextAsync("Hallo Lukas – siehe https://example.com");
var m = await gotB.Task.WaitAsync(TimeSpan.FromSeconds(5));
Check(m.Text == "Hallo Lukas – siehe https://example.com" && m.Payload.SenderName == "Georg", "Text kommt bei B per WebSocket an");
Check(a.Messages.Count(x => x.Id == id) == 1, "Keine Duplikate beim Sender");

// Kleines PNG (1x1)
var png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==");
await a.SendImageAsync(png, "test.png", 1, 1);
var im = await gotImg.Task.WaitAsync(TimeSpan.FromSeconds(5));
var bytes = await b.GetImageBytesAsync(im.Image!);
Check(bytes.SequenceEqual(png), "Bild bei B entschlüsselt identisch");

Check(b.UnreadCount == 2, $"B hat 2 ungelesen ({b.UnreadCount})");
await b.MarkReadAsync();
Check(b.UnreadCount == 0, "B nach MarkRead 0 ungelesen");
await readA.Task.WaitAsync(TimeSpan.FromSeconds(5));
Check(a.OtherReadUpTo >= id, "A sieht Lesebestätigung");

// --- Neuer Client lädt Verlauf
var c = new ChatSession(Entry("Georg-2"), () => { });
_ = c.RunAsync();
await WaitUntil(() => c.State == ConnectionState.Online, "dritter Client online");
Check(c.Messages.Count == 2, $"Verlauf persistent geladen ({c.Messages.Count} Nachrichten)");

// --- Falscher Token für denselben Raum wird abgewiesen
using (var http = new HttpClient())
{
    http.DefaultRequestHeaders.Authorization = new("Bearer", "falsch");
    var res = await http.GetAsync($"{server.TrimEnd('/')}/v1/rooms/{keys.RoomId}/messages");
    Check((int)res.StatusCode == 401, $"Falscher Token → {(int)res.StatusCode}");
}

// --- Server sieht keinen Klartext
if (server.Contains("localhost"))
{
    using var http = new HttpClient();
    var dump = await http.GetStringAsync($"{server.TrimEnd('/')}/debug/dump");
    Check(!dump.Contains("Lukas") && !dump.Contains("example.com"), "Server-Dump enthält keinen Klartext");
}

a.Dispose(); b.Dispose(); c.Dispose();
Console.WriteLine(failures == 0 ? "\nALLE TESTS OK" : $"\n{failures} FEHLER");
return failures == 0 ? 0 : 1;

static bool Throws(Action act) { try { act(); return false; } catch { return true; } }

static async Task WaitUntil(Func<bool> cond, string what)
{
    for (int i = 0; i < 100 && !cond(); i++) await Task.Delay(50);
    if (!cond()) throw new TimeoutException("Timeout: " + what);
}
