import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat {
    /// Maximal erlaubte Bildgröße vor dem Verschlüsseln (Server-Limit 25 MB inkl. Overhead).
    public static let maxImageBytes: Int64 = 24 * 1024 * 1024
    /// Maximale Pixelzahl, die der Client dekodiert (Schutz vor Speicher-Bomben).
    public static let maxPixels: Int64 = 100_000_000

    /// Erkennt PNG/JPEG an den Magic Bytes. Andere Formate werden abgelehnt.
    public static func detectMime(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(8))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        return nil
    }

    public static func formatSize(_ bytes: Int64) -> String {
        let de = Locale(identifier: "de_AT")
        switch bytes {
        case ..<1024: return "\(bytes) B"
        case ..<(1024 * 1024):
            return (Double(bytes) / 1024).formatted(.number.precision(.fractionLength(0)).locale(de)) + " KB"
        default:
            return (Double(bytes) / (1024 * 1024)).formatted(.number.precision(.fractionLength(1)).locale(de)) + " MB"
        }
    }

    public static func shortType(_ mime: String) -> String { mime == "image/png" ? "PNG" : "JPG" }

    /// Bereinigt einen vom Gegenüber gelieferten Dateinamen: keine Pfade, Steuer- oder
    /// Bidi-Zeichen, begrenzte Länge, Endung passend zum tatsächlichen Format.
    public static func safeFileName(_ name: String?, mime: String?) -> String {
        let ext = mime == "image/png" ? ".png" : ".jpg"
        let last = (name ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var cleaned = String.UnicodeScalarView()
        for u in last.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format: continue
            default: break
            }
            if u == ":" || u == "/" || u == "\\" { continue }
            cleaned.append(u)
        }
        var stem = String(cleaned)
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex || stem.count > 1 {
            stem = String(stem[..<dot])
        }
        stem = stem.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if stem.isEmpty { stem = "bild" }
        if stem.count > 80 { stem = String(stem.prefix(80)) }
        return stem + ext
    }

    /// Bildmaße aus dem Header, ohne zu dekodieren.
    public static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Wandelt TIFF (macOS-Zwischenablage) in PNG um.
    public static func pngData(fromTIFF data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, nil)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }
}
