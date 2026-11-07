using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Windows.Forms;
using ImgShare.Core;
using Microsoft.Win32;

namespace ImgShare.Tray;

/// <summary>Symbol im Infobereich mit Menü und Benachrichtigungen.</summary>
public sealed class TrayController : IDisposable
{
    readonly App _app;
    readonly NotifyIcon _icon;
    readonly ContextMenuStrip _menu;
    ChatSession? _lastNotified;
    bool _unread;

    public TrayController(App app)
    {
        _app = app;
        _menu = new ContextMenuStrip
        {
            Font = new Font("Segoe UI", 9.75f),
            ShowImageMargin = false,
            ShowCheckMargin = true,
            Padding = new Padding(4),
        };
        _menu.Opening += (_, _) => BuildMenu();
        _icon = new NotifyIcon
        {
            Icon = IconFactory.CreateTrayIcon(false),
            Text = "Bildsharing",
            ContextMenuStrip = _menu,
            Visible = true,
        };
        _icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) _app.OpenDefaultChat(); };
        _icon.BalloonTipClicked += (_, _) =>
        {
            // Der Chat könnte inzwischen entfernt worden sein.
            if (_lastNotified is not null && _app.Sessions.Contains(_lastNotified)) _app.OpenChat(_lastNotified);
            else _app.OpenDefaultChat();
        };
        ApplyTheme(Ui.ThemeManager.IsDark);
    }

    public void ApplyTheme(bool dark) => _menu.Renderer = new MenuRenderer(dark);

    void BuildMenu()
    {
        _menu.Items.Clear();
        foreach (var s in _app.Sessions)
        {
            int n = s.UnreadCount;
            var item = new ToolStripMenuItem($"Chat mit {s.Entry.ChatName}")
            {
                Font = new Font(_menu.Font, n > 0 ? FontStyle.Bold : FontStyle.Regular),
                // Zähler rechtsbündig in der Kürzel-Spalte, wie im Entwurf
                ShortcutKeyDisplayString = n > 0 ? n.ToString() : null,
                ShowShortcutKeys = n > 0,
                AccessibleName = n > 0 ? $"Chat mit {s.Entry.ChatName}, {n} ungelesen" : $"Chat mit {s.Entry.ChatName}",
            };
            item.Click += (_, _) => _app.OpenChat(s);
            _menu.Items.Add(item);
        }
        _menu.Items.Add("Neuen Chat einrichten …", null, (_, _) => _app.OpenSetup(null));
        _menu.Items.Add(new ToolStripSeparator());

        var pause = new ToolStripMenuItem("Benachrichtigungen pausieren") { Checked = _app.Config.NotificationsPaused };
        pause.Click += (_, _) => { _app.Config.NotificationsPaused = !_app.Config.NotificationsPaused; _app.SaveConfig(); };
        _menu.Items.Add(pause);

        bool autostart = false;
        try { autostart = Autostart.IsEnabled; } catch { /* Registry nicht lesbar */ }
        var auto = new ToolStripMenuItem("Mit Windows starten") { Checked = autostart };
        auto.Click += (_, _) =>
        {
            try { Autostart.Set(!autostart); }
            catch (Exception ex)
            {
                System.Windows.MessageBox.Show("Autostart konnte nicht geändert werden: " + ex.Message, "Bildsharing");
            }
        };
        _menu.Items.Add(auto);

        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add("Beenden", null, (_, _) => _app.Quit());
    }

    public void UpdateUnread(int total)
    {
        bool unread = total > 0;
        _icon.Text = unread ? $"Bildsharing – {total} ungelesen" : "Bildsharing";
        if (unread == _unread) return;
        _unread = unread;
        var old = _icon.Icon;
        _icon.Icon = IconFactory.CreateTrayIcon(unread);
        old?.Dispose();
    }

    /// <summary>Benachrichtigung; ein Klick öffnet <paramref name="session"/> (null = Standard-Chat).</summary>
    public void Notify(ChatSession? session, string title, string text)
    {
        _lastNotified = session;
        _icon.ShowBalloonTip(5000, title, text, ToolTipIcon.None);
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
        _menu.Dispose();
    }

    sealed class MenuRenderer : ToolStripProfessionalRenderer
    {
        readonly bool _dark;
        public MenuRenderer(bool dark) : base(new Colors(dark)) { _dark = dark; RoundedEdges = false; }

        Color TextColor => _dark ? Color.FromArgb(0xE7, 0xE9, 0xEC) : Color.FromArgb(0x1B, 0x1D, 0x21);
        Color CounterColor => _dark ? Color.FromArgb(0x7F, 0xB8, 0xEE) : Color.FromArgb(0x0F, 0x5F, 0xA8);

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            bool isCounter = e.Item is ToolStripMenuItem { ShortcutKeyDisplayString: { } sc } && e.Text == sc;
            e.TextColor = isCounter ? CounterColor : TextColor;
            base.OnRenderItemText(e);
        }

        // Häkchen selbst zeichnen: das Standard-Glyph ist im Dunkelmodus kaum sichtbar.
        protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
        {
            var r = e.ImageRectangle;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var pen = new Pen(TextColor, 2f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
            e.Graphics.DrawLines(pen, new[]
            {
                new PointF(r.X + r.Width * 0.18f, r.Y + r.Height * 0.52f),
                new PointF(r.X + r.Width * 0.42f, r.Y + r.Height * 0.76f),
                new PointF(r.X + r.Width * 0.84f, r.Y + r.Height * 0.28f),
            });
        }

        sealed class Colors : ProfessionalColorTable
        {
            readonly bool _d;
            public Colors(bool dark) { _d = dark; UseSystemColors = false; }
            Color Bg => _d ? Color.FromArgb(0x1F, 0x22, 0x27) : Color.White;
            Color Hover => _d ? Color.FromArgb(0x2A, 0x2E, 0x35) : Color.FromArgb(0xEE, 0xF3, 0xF9);
            Color Line => _d ? Color.FromArgb(0x3A, 0x3F, 0x47) : Color.FromArgb(0xD9, 0xDC, 0xE1);
            public override Color ToolStripDropDownBackground => Bg;
            public override Color MenuBorder => Line;
            public override Color MenuItemBorder => Hover;
            public override Color MenuItemSelected => Hover;
            public override Color MenuItemSelectedGradientBegin => Hover;
            public override Color MenuItemSelectedGradientEnd => Hover;
            public override Color SeparatorDark => Line;
            public override Color SeparatorLight => Bg;
            public override Color ImageMarginGradientBegin => Bg;
            public override Color ImageMarginGradientMiddle => Bg;
            public override Color ImageMarginGradientEnd => Bg;
            public override Color CheckBackground => Bg;
            public override Color CheckSelectedBackground => Hover;
            public override Color CheckPressedBackground => Hover;
            public override Color ButtonSelectedBorder => Hover;
        }
    }
}

public static class Autostart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "ImgShare";

    public static bool IsEnabled
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue(Name) is string;
        }
    }

    public static void Set(bool enabled)
    {
        using var k = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) k.SetValue(Name, $"\"{Environment.ProcessPath}\" --tray");
        else k.DeleteValue(Name, false);
    }
}
