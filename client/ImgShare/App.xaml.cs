using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using ImgShare.Core;
using ImgShare.Tray;
using ImgShare.Ui;

namespace ImgShare;

public partial class App : Application
{
    /// <summary>
    /// Vorbelegung für das Server-Feld. Kommt beim Bauen aus der MSBuild-Eigenschaft
    /// bzw. Umgebungsvariable <c>DefaultServer</c> (in der CI aus der Repo-Variable
    /// <c>IMGSHARE_DEFAULT_SERVER</c>), damit keine Serveradresse im Quellcode steht.
    /// </summary>
    public static readonly string DefaultServer =
        typeof(App).Assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyMetadataAttribute), false)
            .OfType<System.Reflection.AssemblyMetadataAttribute>()
            .FirstOrDefault(a => a.Key == "DefaultServer" && !string.IsNullOrWhiteSpace(a.Value))?.Value
        ?? "https://";

    Mutex? _mutex;
    EventWaitHandle? _showSignal;
    TrayController? _tray;
    readonly List<ChatSession> _sessions = new();
    readonly Dictionary<ChatSession, ChatWindow> _windows = new();

    public AppConfig Config { get; private set; } = new();
    public IReadOnlyList<ChatSession> Sessions => _sessions;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Nur eine Instanz; ein zweiter Start holt das Fenster der ersten nach vorne.
        var suffix = AppConfig.HomeOverride is { } home
            ? "." + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(home.ToLowerInvariant())))[..12]
            : "";
        _mutex = new Mutex(true, @"Local\ImgShare.SingleInstance" + suffix, out bool first);
        if (!first)
        {
            try { EventWaitHandle.OpenExisting(@"Local\ImgShare.Show" + suffix).Set(); } catch { }
            Shutdown();
            return;
        }
        _showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\ImgShare.Show" + suffix);
        new Thread(() =>
        {
            while (_showSignal.WaitOne()) Dispatcher.BeginInvoke(OpenDefaultChat);
        }) { IsBackground = true }.Start();

        DispatcherUnhandledException += (_, ex) =>
        {
            Log(ex.Exception);
            MessageBox.Show(ex.Exception.Message, "Bildsharing – Fehler", MessageBoxButton.OK, MessageBoxImage.Error);
            ex.Handled = true;
        };

        ThemeManager.Init();
        Config = AppConfig.Load();
        _tray = new TrayController(this);
        ThemeManager.Changed += () => _tray?.ApplyTheme(ThemeManager.IsDark);

        foreach (var entry in Config.Chats.ToList()) StartSession(entry);

        if (Config.Chats.Count == 0) OpenSetup(null);
        else if (!e.Args.Contains("--tray")) OpenDefaultChat();
    }

    static void Log(Exception ex)
    {
        try
        {
            Directory.CreateDirectory(AppConfig.ConfigDir);
            File.AppendAllText(Path.Combine(AppConfig.ConfigDir, "error.log"), $"{DateTime.Now:O} {ex}\n\n");
        }
        catch { }
    }

    public void SaveConfig()
    {
        try { Config.Save(); }
        catch (Exception ex) { Log(ex); }
    }

    ChatSession? StartSession(ChatEntry entry)
    {
        ChatSession s;
        try { s = new ChatSession(entry, SaveConfig); }
        catch (Exception ex)
        {
            // z. B. Config von anderem Windows-Benutzer kopiert → DPAPI kann nicht entschlüsseln
            Log(ex);
            MessageBox.Show($"Der Chat „{entry.ChatName}“ kann nicht geöffnet werden: {ex.Message}", "Bildsharing");
            return null;
        }
        s.MessageAdded += (m, live) => OnMessage(s, m, live);
        s.UnreadChanged += UpdateTray;
        _sessions.Add(s);
        _ = s.RunAsync();
        return s;
    }

    void OnMessage(ChatSession s, ChatMessage m, bool live)
    {
        if (!live || m.IsMine) return;
        bool windowActive = _windows.TryGetValue(s, out var w) && w.IsVisible && w.IsActive;
        if (windowActive || Config.NotificationsPaused) return;
        var preview = m.Kind == MessageKind.Image
            ? "hat ein Bild geteilt"
            : (m.Text!.Length > 120 ? m.Text[..120] + " …" : m.Text);
        // Mehrere ungelesene Nachrichten in einer Benachrichtigung bündeln.
        int unread = s.UnreadCount;
        var text = unread > 1 ? $"{unread} neue Nachrichten – zuletzt: {preview}" : preview;
        _tray?.Notify(s, s.Entry.ChatName, text);
    }

    /// <summary>Einmaliger Hinweis, dass das Programm im Infobereich weiterläuft.</summary>
    void ShowTrayHint(bool noChatYet)
    {
        if (noChatYet)
        {
            _tray?.Notify(null, "Bildsharing läuft im Infobereich",
                "Rechtsklick auf das Symbol → „Neuen Chat einrichten …“, wenn du so weit bist.");
            return;
        }
        if (Config.TrayHintShown) return;
        Config.TrayHintShown = true;
        SaveConfig();
        _tray?.Notify(null, "Bildsharing läuft weiter",
            "Das Fenster ist im Infobereich. Ein Klick auf das Symbol öffnet den Chat wieder.");
    }

    void UpdateTray() => _tray?.UpdateUnread(_sessions.Sum(x => x.UnreadCount));

    public void OpenChat(ChatSession s)
    {
        if (!_windows.TryGetValue(s, out var w))
        {
            int cascade = _windows.Values.Count(x => x.IsVisible);
            w = new ChatWindow(s, cascade, SaveConfig);
            w.SettingsRequested += () => OpenSetup(s);
            w.HiddenToTray += () => ShowTrayHint(false);
            _windows[s] = w;
        }
        w.ShowAndActivate();
    }

    public void OpenDefaultChat()
    {
        var s = _sessions.OrderByDescending(x => x.UnreadCount).FirstOrDefault();
        if (s is null) OpenSetup(null); else OpenChat(s);
    }

    SetupWindow? _setup;

    public void OpenSetup(ChatSession? existing)
    {
        if (_setup is not null) { _setup.Activate(); return; }
        var defaultName = Config.Chats.FirstOrDefault()?.MyName ?? Environment.UserName;
        _setup = new SetupWindow(existing?.Entry, DefaultServer, defaultName,
            room => _sessions.Any(x => x.Keys.RoomId == room));
        if (existing is not null && _windows.TryGetValue(existing, out var owner) && owner.IsVisible)
        {
            _setup.Owner = owner;
            _setup.WindowStartupLocation = WindowStartupLocation.CenterOwner;
        }
        bool ok = _setup.ShowDialog() == true;
        var result = _setup.Result;
        var remove = _setup.RemoveRequested;
        _setup = null;
        if (!ok || result is null)
        {
            if (existing is null && _sessions.Count == 0) ShowTrayHint(noChatYet: true);
            return;
        }

        if (existing is null)
        {
            Config.Chats.Add(result);
            SaveConfig();
            if (StartSession(result) is { } s) OpenChat(s);
            return;
        }

        // bestehenden Chat ändern oder entfernen: Sitzung neu aufbauen
        bool reopen = _windows.TryGetValue(existing, out var oldWindow) && oldWindow.IsVisible;
        StopSession(existing);
        if (remove)
        {
            Config.Chats.Remove(result);
            SaveConfig();
            UpdateTray();
            return;
        }
        SaveConfig();
        if (StartSession(result) is { } restarted && reopen) OpenChat(restarted);
    }

    void StopSession(ChatSession s)
    {
        if (_windows.Remove(s, out var w)) w.CloseForGood();
        _sessions.Remove(s);
        s.Dispose();
    }

    public void Quit()
    {
        foreach (var s in _sessions.ToList()) StopSession(s);
        _tray?.Dispose();
        _tray = null;
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        base.OnExit(e);
    }
}
