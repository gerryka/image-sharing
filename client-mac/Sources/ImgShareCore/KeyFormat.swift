import Foundation

/// Darstellung des Root-Keys als Base32 (RFC 4648, ohne Padding) in 4er-Gruppen.
public enum KeyFormat {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func format(_ key: Data) -> String {
        var raw: [Character] = []
        var buffer = 0, bits = 0
        for b in key {
            buffer = (buffer << 8) | Int(b); bits += 8
            while bits >= 5 { raw.append(alphabet[(buffer >> (bits - 5)) & 31]); bits -= 5 }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { raw.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return stride(from: 0, to: raw.count, by: 4)
            .map { String(raw[$0..<min($0 + 4, raw.count)]) }
            .joined(separator: "-")
    }

    /// Tolerant: Kleinbuchstaben, Trennzeichen, 0→O und 1→I. Nil bei Tippfehlern.
    public static func parse(_ text: String?) -> Data? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var values: [Int] = []
        for ch in text.uppercased() {
            let c: Character = ch == "0" ? "O" : ch == "1" ? "I" : ch
            if let i = alphabet.firstIndex(of: c) {
                values.append(i)
            } else if c.isLetter || c.isNumber {
                return nil
            }
        }
        var bytes = Data()
        var buffer = 0, bits = 0
        for v in values {
            buffer = (buffer << 5) | v; bits += 5
            if bits >= 8 { bytes.append(UInt8(buffer >> (bits - 8))); bits -= 8 }
            buffer &= (1 << bits) - 1
        }
        guard bytes.count == ChatKeys.rootKeyLength, buffer == 0 else { return nil }
        return bytes
    }
}
