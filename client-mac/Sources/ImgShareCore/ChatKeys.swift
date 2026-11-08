import CryptoKit
import Foundation

public enum CryptoError: Error, Equatable, Sendable {
    case invalidKeyLength
    case dataTooShort
    case authenticationFailed
}

/// Alle aus dem vorab geteilten Root-Key abgeleiteten Werte (docs/PROTOCOL.md, Abschnitt 2).
public struct ChatKeys: Sendable {
    public static let rootKeyLength = 32
    static let salt = Data("imgshare-v1".utf8)

    public let encKey: SymmetricKey
    public let roomId: String
    public let token: Data
    public let safetyCode: String

    public static func derive(rootKey: Data) throws -> ChatKeys {
        guard rootKey.count == rootKeyLength else { throw CryptoError.invalidKeyLength }
        let ikm = SymmetricKey(data: rootKey)
        func kdf(_ info: String, _ len: Int) -> Data {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data(info.utf8), outputByteCount: len)
                .withUnsafeBytes { Data($0) }
        }
        let enc = SymmetricKey(data: kdf("enc", 32))
        let room = kdf("room", 16).map { String(format: "%02x", $0) }.joined()
        let token = kdf("auth", 32)
        // .NET BitConverter.ToUInt64 liest Little-Endian.
        let n = kdf("safety", 8).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
            % 1_000_000_000_000
        let s = Array(String(format: "%012llu", n))
        let safety = "\(String(s[0..<3])) \(String(s[3..<6])) · \(String(s[6..<9])) \(String(s[9..<12]))"
        return ChatKeys(encKey: enc, roomId: room, token: token, safetyCode: safety)
    }

    public static func generateRootKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// Token als base64url ohne Padding (für den Authorization-Header).
    public var tokenBase64URL: String {
        token.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// AES-256-GCM: Ausgabe = nonce(12) || ciphertext || tag(16), AAD = room_id.
    public func encrypt(_ plaintext: Data) throws -> Data {
        try seal(plaintext, nonce: AES.GCM.Nonce())
    }

    func encrypt(_ plaintext: Data, nonce: Data) throws -> Data {
        try seal(plaintext, nonce: AES.GCM.Nonce(data: nonce))
    }

    private func seal(_ plaintext: Data, nonce: AES.GCM.Nonce) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: encKey, nonce: nonce, authenticating: Data(roomId.utf8))
        return box.combined!
    }

    public func decrypt(_ data: Data) throws -> Data {
        guard data.count >= 28 else { throw CryptoError.dataTooShort }
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(box, using: encKey, authenticating: Data(roomId.utf8))
        } catch {
            throw CryptoError.authenticationFailed
        }
    }
}
