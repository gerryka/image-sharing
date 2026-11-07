using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Forms = System.Windows.Forms;

namespace ImgShare.Ui;

/// <summary>Monitor-bewusste Fensterplatzierung (Multi-Monitor, unterschiedliche DPI).</summary>
public static class WindowPlacement
{
    static double Scale(Visual v)
    {
        try { return VisualTreeHelper.GetDpi(v).DpiScaleX; } catch { return 1.0; }
    }

    static Rect ToDip(System.Drawing.Rectangle r, double s) => new(r.Left / s, r.Top / s, r.Width / s, r.Height / s);

    /// <summary>Arbeitsbereich (ohne Taskleiste) des Monitors, auf dem das Fenster liegt, in DIPs.</summary>
    public static Rect WorkAreaOf(Window w)
    {
        var hwnd = new WindowInteropHelper(w).Handle;
        var screen = hwnd != IntPtr.Zero ? Forms.Screen.FromHandle(hwnd) : Forms.Screen.PrimaryScreen!;
        return ToDip(screen.WorkingArea, Scale(w));
    }

    /// <summary>
    /// Stellt gespeicherte Bounds wieder her, wenn sie noch auf einem vorhandenen Monitor sichtbar sind;
    /// sonst unten rechts auf dem Hauptmonitor, versetzt um <paramref name="cascade"/> Schritte.
    /// </summary>
    public static void Restore(Window w, double[]? bounds, int cascade)
    {
        var s = Scale(w);
        if (bounds is { Length: 4 } b && b[2] >= w.MinWidth && b[3] >= w.MinHeight)
        {
            var r = new Rect(b[0], b[1], b[2], b[3]);
            bool visible = Forms.Screen.AllScreens.Any(sc =>
            {
                var wa = ToDip(sc.WorkingArea, s);
                var i = Rect.Intersect(wa, r);
                return !i.IsEmpty && i.Width >= 120 && i.Height >= 60;
            });
            if (visible)
            {
                w.Left = r.Left; w.Top = r.Top; w.Width = r.Width; w.Height = r.Height;
                return;
            }
        }
        var area = ToDip(Forms.Screen.PrimaryScreen!.WorkingArea, s);
        w.Width = Math.Min(w.Width, area.Width - 32);
        w.Height = Math.Min(w.Height, area.Height - 32);
        w.Left = area.Right - w.Width - 16 - cascade * 28;
        w.Top = area.Bottom - w.Height - 16 - cascade * 28;
    }

    public static double[] Capture(Window w)
    {
        var r = w.WindowState == WindowState.Normal ? new Rect(w.Left, w.Top, w.Width, w.Height) : w.RestoreBounds;
        return new[] { r.Left, r.Top, r.Width, r.Height };
    }

    /// <summary>Größe auf max. 90 % des Owner-Monitors begrenzen und dort zentrieren.</summary>
    public static void CenterOnOwnerMonitor(Window w, Window? owner)
    {
        var area = owner is not null ? WorkAreaOf(owner) : ToDip(Forms.Screen.PrimaryScreen!.WorkingArea, Scale(w));
        w.WindowStartupLocation = WindowStartupLocation.Manual;
        w.Width = Math.Min(w.Width, area.Width * 0.9);
        w.Height = Math.Min(w.Height, area.Height * 0.9);
        w.Left = area.Left + (area.Width - w.Width) / 2;
        w.Top = area.Top + (area.Height - w.Height) / 2;
    }

    // ---- Maximieren ohne Taskleiste zu verdecken (WindowStyle=None + WindowChrome)

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct MINMAXINFO { public POINT Reserved, MaxSize, MaxPosition, MinTrackSize, MaxTrackSize; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    struct MONITORINFO { public int Size; public RECT Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO info);

    /// <summary>Begrenzt „Maximieren“ auf den Arbeitsbereich des Monitors, auf dem das Fenster liegt.</summary>
    public static void FixMaximize(Window w)
    {
        var src = HwndSource.FromHwnd(new WindowInteropHelper(w).Handle);
        src?.AddHook((IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) =>
        {
            const int WM_GETMINMAXINFO = 0x0024;
            if (msg != WM_GETMINMAXINFO) return IntPtr.Zero;
            var mon = MonitorFromWindow(hwnd, 2 /* MONITOR_DEFAULTTONEAREST */);
            var info = new MONITORINFO { Size = Marshal.SizeOf<MONITORINFO>() };
            if (mon == IntPtr.Zero || !GetMonitorInfo(mon, ref info)) return IntPtr.Zero;
            var mmi = Marshal.PtrToStructure<MINMAXINFO>(lParam);
            mmi.MaxPosition.X = info.Work.Left - info.Monitor.Left;
            mmi.MaxPosition.Y = info.Work.Top - info.Monitor.Top;
            mmi.MaxSize.X = info.Work.Right - info.Work.Left;
            mmi.MaxSize.Y = info.Work.Bottom - info.Work.Top;
            Marshal.StructureToPtr(mmi, lParam, true);
            handled = false; // WPF ergänzt MinTrackSize aus MinWidth/MinHeight
            return IntPtr.Zero;
        });
    }

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    /// <summary>Native Titelleiste an den Dunkelmodus anpassen (Windows 10 20H1+ / 11).</summary>
    public static void ApplyTitleBarTheme(Window w, bool dark)
    {
        var hwnd = new WindowInteropHelper(w).Handle;
        if (hwnd == IntPtr.Zero) return;
        int v = dark ? 1 : 0;
        if (DwmSetWindowAttribute(hwnd, 20, ref v, sizeof(int)) != 0)
            DwmSetWindowAttribute(hwnd, 19, ref v, sizeof(int)); // ältere Builds
    }
}
