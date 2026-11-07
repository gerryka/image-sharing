using System.Text;
using System.Text.Json;

namespace ImgShare.Core;

public sealed class ChatEntry
{
    static readonly byte[] Entropy = Encoding.ASCII.GetBytes("ImgShare.v1");

    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string ServerUrl { get; set; } = "";
    public string MyName { get; set; } = "";
    public string ChatName { get; set; } = "";
    /// <summary>Root-Key, mit Windows DPAPI an den aktuellen Benutzer gebunden.</summary>
    public string ProtectedKey { get; set; } = "";
    /// <summary>Zufällige Geräte-ID: unterscheidet eigene von fremden Nachrichten.</summary>
    public string DeviceId { get; set; } = Guid.NewGuid().ToString("N");
    /// <summary>Höchste gelesene fremde Nachricht (lokal, für Ungelesen-Zähler).</summary>
    public long LastReadId { get; set; }

    /// <summary>Zuletzt genutzte Fensterposition/-größe in geräteunabhängigen Pixeln.</summary>
    public double[]? WindowBounds { get; set; }

    /// <summary>Server-Zugangscode zum Anlegen neuer Chats (optional), ebenfalls per DPAPI geschützt.</summary>
    public string ProtectedInvite { get; set; } = "";

    public byte[] GetRootKey() => Dpapi.Unprotect(Convert.FromBase64String(ProtectedKey), Entropy);

    public void SetRootKey(byte[] key) => ProtectedKey = Convert.ToBase64String(Dpapi.Protect(key, Entropy));

    public string GetInvite() => ProtectedInvite.Length == 0 ? "" :
        Encoding.UTF8.GetString(Dpapi.Unprotect(Convert.FromBase64String(ProtectedInvite), Entropy));

    public void SetInvite(string? invite) => ProtectedInvite = string.IsNullOrWhiteSpace(invite) ? "" :
        Convert.ToBase64String(Dpapi.Protect(Encoding.UTF8.GetBytes(invite.Trim()), Entropy));
}

public sealed class AppConfig
{
    public List<ChatEntry> Chats { get; set; } = new();
    public bool NotificationsPaused { get; set; }
    /// <summary>Hinweis „läuft im Infobereich weiter“ wurde schon einmal gezeigt.</summary>
    public bool TrayHintShown { get; set; }

    /// <summary>Optional: IMGSHARE_HOME legt Config und Cache in einen eigenen Ordner (Tests, zweite Instanz).</summary>
    public static string? HomeOverride => Environment.GetEnvironmentVariable("IMGSHARE_HOME") is { Length: > 0 } h ? h : null;

    public static string ConfigDir => HomeOverride ??
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ImgShare");

    public static string CacheDir => HomeOverride is { } h ? Path.Combine(h, "cache") :
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ImgShare", "cache");

    static string ConfigPath => Path.Combine(ConfigDir, "config.json");
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public static AppConfig Load()
    {
        try
        {
            if (File.Exists(ConfigPath))
                return JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(ConfigPath)) ?? new AppConfig();
        }
        catch { /* kaputte Config: neu anfangen, alte bleibt als .bak */
            try { File.Copy(ConfigPath, ConfigPath + ".bak", true); } catch { }
        }
        return new AppConfig();
    }

    public void Save()
    {
        Directory.CreateDirectory(ConfigDir);
        var tmp = ConfigPath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, Json));
        File.Move(tmp, ConfigPath, true);
    }
}
