import AppKit
import ImgShareCore
import UniformTypeIdentifiers

/// Liest ein Bild (PNG/JPEG, TIFF wird zu PNG) aus Zwischenablage, Datei oder Drag & Drop.
enum PasteboardImage {
    struct Picked: Equatable {
        let data: Data
        let fileName: String
    }

    static func timestampName(ext: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Bild \(f.string(from: Date())).\(ext)"
    }

    /// nil, wenn die Zwischenablage kein Bild enthält.
    static func read(from pb: NSPasteboard) -> Picked? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let picked = try? read(fileURL: url) {
            return picked
        }
        return read(data: pb.data(forType: .png), type: .png)
            ?? read(data: pb.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)), type: .jpeg)
            ?? read(data: pb.data(forType: .tiff), type: .tiff)
    }

    static func hasImage(_ pb: NSPasteboard) -> Bool {
        let types: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier)]
        if pb.availableType(from: types) != nil { return true }
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.contains { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) } ?? false
    }

    static func read(data: Data?, type: UTType) -> Picked? {
        guard let data else { return nil }
        if type == .tiff {
            guard let png = ImageFormat.pngData(fromTIFF: data) else { return nil }
            return Picked(data: png, fileName: timestampName(ext: "png"))
        }
        guard let mime = ImageFormat.detectMime(data) else { return nil }
        return Picked(data: data, fileName: timestampName(ext: mime == "image/png" ? "png" : "jpg"))
    }

    static func read(fileURL url: URL) throws -> Picked {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard Int64(size) <= ImageFormat.maxImageBytes else { throw ImageError.tooLarge }
        let data = try Data(contentsOf: url)
        guard let mime = ImageFormat.detectMime(data) else { throw ImageError.unsupportedFormat }
        return Picked(data: data, fileName: ImageFormat.safeFileName(url.lastPathComponent, mime: mime))
    }

    /// Drag & Drop: Datei-URLs oder rohe Bilddaten (z. B. aus Fotos oder dem Browser).
    @MainActor static func load(from providers: [NSItemProvider]) async -> Result<Picked, Error>? {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = try? await p.loadDataRepresentation(for: .fileURL),
               let fileURL = URL(dataRepresentation: url, relativeTo: nil) {
                return Result { try read(fileURL: fileURL) }
            }
            for type in [UTType.png, .jpeg, .tiff] where p.hasItemConformingToTypeIdentifier(type.identifier) {
                if let data = try? await p.loadDataRepresentation(for: type), let picked = read(data: data, type: type) {
                    return .success(picked)
                }
            }
        }
        return nil
    }
}

extension NSItemProvider {
    @MainActor func loadDataRepresentation(for type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            _ = loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { c.resume(returning: data) } else { c.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}
