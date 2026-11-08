import Foundation

// MARK: - Wire-Format des Servers

public struct EncryptedMessage: Codable, Sendable, Equatable {
    public var id: Int64
    public var serverTs: Date
    public var ciphertext: String

    public init(id: Int64, serverTs: Date, ciphertext: String) {
        self.id = id; self.serverTs = serverTs; self.ciphertext = ciphertext
    }

    enum CodingKeys: String, CodingKey {
        case id, ciphertext
        case serverTs = "server_ts"
    }
}

public struct MessagesPage: Codable, Sendable, Equatable {
    public var messages: [EncryptedMessage]
    public var hasMore: Bool

    public init(messages: [EncryptedMessage], hasMore: Bool) {
        self.messages = messages; self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
    }
}

public struct PostMessageResult: Codable, Sendable, Equatable {
    public var id: Int64
    public var serverTs: Date

    public init(id: Int64, serverTs: Date) { self.id = id; self.serverTs = serverTs }

    enum CodingKeys: String, CodingKey {
        case id
        case serverTs = "server_ts"
    }
}

public struct BlobResult: Codable, Sendable, Equatable {
    public var blobId: String
    public var size: Int64

    public init(blobId: String, size: Int64) { self.blobId = blobId; self.size = size }

    enum CodingKeys: String, CodingKey {
        case blobId = "blob_id"
        case size
    }
}

// MARK: - Verschlüsselter Klartext (nur Clients sehen das)

public enum MessageKind: String, Sendable {
    case text, image, read
}

public struct Payload: Codable, Sendable, Equatable {
    public var v: Int
    public var kind: String
    public var sender: String
    public var senderName: String
    public var sentAt: Date
    public var text: String?
    public var image: ImageInfo?
    public var readUpTo: Int64?

    public init(v: Int = 1, kind: String, sender: String, senderName: String, sentAt: Date,
                text: String? = nil, image: ImageInfo? = nil, readUpTo: Int64? = nil) {
        self.v = v; self.kind = kind; self.sender = sender; self.senderName = senderName
        self.sentAt = sentAt; self.text = text; self.image = image; self.readUpTo = readUpTo
    }

    /// nil bei unbekannten Arten (neuere Clients) – solche Nachrichten werden ignoriert.
    public var messageKind: MessageKind? { MessageKind(rawValue: kind) }

    enum CodingKeys: String, CodingKey {
        case v, kind, sender, text, image
        case senderName = "sender_name"
        case sentAt = "sent_at"
        case readUpTo = "read_up_to"
    }
}

public struct ImageInfo: Codable, Sendable, Equatable, Hashable {
    public var blobId: String
    public var mime: String
    public var filename: String
    public var size: Int64
    public var width: Int
    public var height: Int

    public init(blobId: String, mime: String, filename: String, size: Int64, width: Int, height: Int) {
        self.blobId = blobId; self.mime = mime; self.filename = filename
        self.size = size; self.width = width; self.height = height
    }

    enum CodingKeys: String, CodingKey {
        case mime, filename, size, width, height
        case blobId = "blob_id"
    }
}

/// Entschlüsselte, anzeigbare Nachricht.
public struct ChatMessage: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let serverTs: Date
    public let payload: Payload
    public let isMine: Bool

    public init(id: Int64, serverTs: Date, payload: Payload, isMine: Bool) {
        self.id = id; self.serverTs = serverTs; self.payload = payload; self.isMine = isMine
    }

    public var kind: MessageKind? { payload.messageKind }
    public var text: String? { payload.text }
    public var image: ImageInfo? { payload.image }
}

public enum ConnectionState: Sendable {
    case connecting, online, offline
}

// MARK: - JSON

/// JSON-Coder für Server- und Klartext-Format.
/// Liest .NET-Zeitstempel (7 Nachkommastellen, Offset) und Go-Zeitstempel (Sekunden, Z).
public enum WireJSON {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parseDate(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Ungültiger Zeitstempel: \(s)")
            }
            return date
        }
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatDate(date))
        }
        return e
    }

    static func parseDate(_ s: String) -> Date? {
        // Nachkommastellen auf 3 kürzen bzw. auffüllen, damit ISO8601DateFormatter sie sicher liest.
        var str = s
        var hasFraction = false
        if let r = str.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = str[r].dropFirst()
            let ms = String((digits + "000").prefix(3))
            str.replaceSubrange(r, with: "." + ms)
            hasFraction = true
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = hasFraction ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.date(from: str)
    }

    static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
