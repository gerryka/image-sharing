import Foundation

/// Bild-Cache auf der Platte. Inhalte bleiben verschlüsselt.
public struct BlobCache: BlobCaching {
    public let root: URL

    public init(root: URL = AppConfig.cacheDir) { self.root = root }

    private func path(_ room: String, _ blobId: String) -> URL? {
        guard room.wholeMatch(of: /^[0-9a-f]{32}$/) != nil,
              blobId.wholeMatch(of: /^[A-Za-z0-9-]{1,64}$/) != nil else { return nil }
        return root.appending(path: room).appending(path: blobId)
    }

    public func read(room: String, blobId: String) -> Data? {
        path(room, blobId).flatMap { try? Data(contentsOf: $0) }
    }

    public func write(room: String, blobId: String, data: Data) {
        guard let p = path(room, blobId) else { return }
        // Cache ist optional – Fehler werden ignoriert.
        try? FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: p, options: .atomic)
    }

    public func remove(room: String, blobId: String) {
        guard let p = path(room, blobId) else { return }
        try? FileManager.default.removeItem(at: p)
    }
}
