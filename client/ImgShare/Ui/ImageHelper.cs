using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ImgShare.Core;

namespace ImgShare.Ui;

/// <summary>Ein zum Senden vorbereitetes Bild.</summary>
public sealed record PendingImage(byte[] Bytes, string Mime, string FileName, int Width, int Height, BitmapSource Preview, bool FromClipboard);

public static class ImageHelper
{
    static readonly string[] Extensions = { ".png", ".jpg", ".jpeg" };

    /// <summary>Längste Kante beim Anzeigen in voller Größe (begrenzt den Speicherbedarf).</summary>
    public const int MaxViewEdge = 6000;

    public static bool IsImageFile(string path) => Extensions.Contains(Path.GetExtension(path).ToLowerInvariant());

    /// <summary>Liest nur den Header und liefert die Pixelmaße – ohne das Bild zu dekodieren.</summary>
    public static (int w, int h) Probe(byte[] bytes)
    {
        using var ms = new MemoryStream(bytes, writable: false);
        var dec = BitmapDecoder.Create(ms, BitmapCreateOptions.DelayCreation | BitmapCreateOptions.IgnoreColorProfile,
            BitmapCacheOption.None);
        var f = dec.Frames[0];
        return (f.PixelWidth, f.PixelHeight);
    }

    /// <summary>
    /// Dekodiert ein Bild, höchstens <paramref name="maxEdge"/> Pixel an der längsten Kante.
    /// Lehnt Bilder über <see cref="ImageFormat.MaxPixels"/> ab (Speicher-Bombe).
    /// </summary>
    public static BitmapSource Decode(byte[] bytes, int maxEdge)
    {
        var (w, h) = Probe(bytes);
        if (w <= 0 || h <= 0 || (long)w * h > ImageFormat.MaxPixels)
            throw new InvalidDataException($"Das Bild ist zu groß ({w}×{h} Pixel).");
        var bmp = new BitmapImage();
        bmp.BeginInit();
        bmp.CacheOption = BitmapCacheOption.OnLoad;
        bmp.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
        if (w >= h && w > maxEdge) bmp.DecodePixelWidth = maxEdge;
        else if (h > w && h > maxEdge) bmp.DecodePixelHeight = maxEdge;
        bmp.StreamSource = new MemoryStream(bytes, writable: false);
        bmp.EndInit();
        bmp.Freeze();
        return bmp;
    }

    public static PendingImage FromBytes(byte[] bytes, string fileName, bool fromClipboard)
    {
        var mime = ImageFormat.DetectMime(bytes) ?? throw new InvalidDataException("Nur PNG und JPG werden unterstützt.");
        if (bytes.Length > ImageFormat.MaxImageBytes) throw new InvalidDataException("Das Bild ist größer als 24 MB.");
        var (w, h) = Probe(bytes);
        var preview = Decode(bytes, 560);
        return new PendingImage(bytes, mime, ImageFormat.SafeFileName(fileName, mime), w, h, preview, fromClipboard);
    }

    public static PendingImage FromFile(string path)
    {
        if (!IsImageFile(path)) throw new InvalidDataException("Nur PNG und JPG werden unterstützt.");
        return FromBytes(File.ReadAllBytes(path), Path.GetFileName(path), false);
    }

    static string ClipboardName() => $"bild-{DateTime.Now:yyyy-MM-dd-HHmmss}.png";

    /// <summary>
    /// Liest ein Bild aus der Zwischenablage. Gibt null zurück, wenn dort Text liegt
    /// (dann soll normal eingefügt werden) oder gar kein Bild.
    /// </summary>
    public static PendingImage? TryReadClipboard()
    {
        if (Clipboard.ContainsFileDropList())
        {
            var file = Clipboard.GetFileDropList().Cast<string>().FirstOrDefault(IsImageFile);
            if (file is not null) return FromFile(file);
        }
        if (Clipboard.ContainsText()) return null;

        if (Clipboard.ContainsData("PNG") && Clipboard.GetData("PNG") is MemoryStream png)
            return FromBytes(png.ToArray(), ClipboardName(), true);

        if (Clipboard.ContainsImage() && Clipboard.GetImage() is { } src)
        {
            // DIB aus der Zwischenablage hat oft einen leeren Alphakanal → ohne Alpha speichern
            var opaque = new FormatConvertedBitmap(src, PixelFormats.Bgr32, null, 0);
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(opaque));
            using var ms = new MemoryStream();
            enc.Save(ms);
            return FromBytes(ms.ToArray(), ClipboardName(), true);
        }
        return null;
    }

    public static void CopyToClipboard(byte[] bytes)
    {
        var data = new DataObject();
        data.SetImage(Decode(bytes, MaxViewEdge));
        if (ImageFormat.DetectMime(bytes) == "image/png") data.SetData("PNG", new MemoryStream(bytes));
        Clipboard.SetDataObject(data, true);
    }
}
