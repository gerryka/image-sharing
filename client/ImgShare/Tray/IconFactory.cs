using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ImgShare.Tray;

/// <summary>Zeichnet das App-Symbol (Bildrahmen in Akzentfarbe), optional mit Ungelesen-Punkt.</summary>
public static class IconFactory
{
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr hIcon);

    static readonly System.Drawing.Color Accent = System.Drawing.Color.FromArgb(0x0F, 0x5F, 0xA8);
    static readonly System.Drawing.Color Badge = System.Drawing.Color.FromArgb(0xE8, 0x59, 0x0C);

    static Bitmap Draw(int size, bool unread)
    {
        var bmp = new Bitmap(size, size);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(System.Drawing.Color.Transparent);
        float s = size / 32f;

        using (var path = RoundedRect(new RectangleF(2 * s, 4 * s, 28 * s, 24 * s), 5 * s))
        using (var fill = new SolidBrush(Accent))
            g.FillPath(fill, path);

        using var pen = new System.Drawing.Pen(System.Drawing.Color.White, 2.4f * s) { LineJoin = LineJoin.Round, StartCap = LineCap.Round, EndCap = LineCap.Round };
        // Berge
        g.DrawLines(pen, new[] { new PointF(7 * s, 23 * s), new PointF(13 * s, 16 * s), new PointF(17 * s, 20 * s),
                                 new PointF(20 * s, 17 * s), new PointF(25 * s, 23 * s) });
        // Sonne
        using (var white = new SolidBrush(System.Drawing.Color.White))
            g.FillEllipse(white, 20 * s, 8 * s, 4.5f * s, 4.5f * s);

        if (unread)
        {
            using var outline = new SolidBrush(System.Drawing.Color.White);
            using var dot = new SolidBrush(Badge);
            g.FillEllipse(outline, 19 * s, 0, 13 * s, 13 * s);
            g.FillEllipse(dot, 20.5f * s, 1.5f * s, 10 * s, 10 * s);
        }
        return bmp;
    }

    static GraphicsPath RoundedRect(RectangleF r, float radius)
    {
        var p = new GraphicsPath();
        float d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    /// <summary>Icon für den Infobereich. Aufrufer muss das alte Icon disposen.</summary>
    public static Icon CreateTrayIcon(bool unread)
    {
        var size = System.Windows.Forms.SystemInformation.SmallIconSize.Width;
        using var bmp = Draw(Math.Max(16, size), unread);
        var h = bmp.GetHicon();
        try { return (Icon)Icon.FromHandle(h).Clone(); }
        finally { DestroyIcon(h); }
    }

    public static ImageSource CreateImageSource(bool unread)
    {
        using var bmp = Draw(64, unread);
        var h = bmp.GetHbitmap();
        try
        {
            var src = Imaging.CreateBitmapSourceFromHBitmap(h, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            src.Freeze();
            return src;
        }
        finally { DeleteObject(h); }
    }

    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr hObject);
}
