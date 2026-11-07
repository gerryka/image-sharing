namespace ImgShare.Core;

public static class ImageFormat
{
    /// <summary>Maximal erlaubte Bildgröße vor dem Verschlüsseln (Server-Limit 25 MB inkl. Overhead).</summary>
    public const long MaxImageBytes = 24L * 1024 * 1024;

    /// <summary>Erkennt PNG/JPEG an den Magic Bytes. Andere Formate werden abgelehnt.</summary>
    public static string? DetectMime(ReadOnlySpan<byte> data)
    {
        if (data.Length >= 8 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47)
            return "image/png";
        if (data.Length >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF)
            return "image/jpeg";
        return null;
    }

    public static string FormatSize(long bytes) => bytes switch
    {
        < 1024 => $"{bytes} B",
        < 1024 * 1024 => $"{bytes / 1024.0:0} KB",
        _ => $"{bytes / (1024.0 * 1024):0.0} MB"
    };

    public static string ShortType(string mime) => mime == "image/png" ? "PNG" : "JPG";

    /// <summary>Maximale Pixelzahl, die der Client dekodiert (Schutz vor Speicher-Bomben).</summary>
    public const long MaxPixels = 100_000_000;

    /// <summary>
    /// Bereinigt einen vom Gegenüber gelieferten Dateinamen: keine Pfade, Steuer- oder
    /// Bidi-Zeichen, begrenzte Länge, Endung passend zum tatsächlichen Format.
    /// </summary>
    public static string SafeFileName(string? name, string? mime)
    {
        var ext = mime == "image/png" ? ".png" : ".jpg";
        var raw = Path.GetFileName(name ?? "") ?? "";
        var invalid = Path.GetInvalidFileNameChars();
        var sb = new System.Text.StringBuilder();
        foreach (var ch in raw)
        {
            var cat = char.GetUnicodeCategory(ch);
            if (char.IsControl(ch) || cat == System.Globalization.UnicodeCategory.Format || invalid.Contains(ch)) continue;
            sb.Append(ch);
        }
        var stem = Path.GetFileNameWithoutExtension(sb.ToString()).Trim().Trim('.');
        if (stem.Length == 0) stem = "bild";
        if (stem.Length > 80) stem = stem[..80];
        return stem + ext;
    }
}
