import Foundation

struct Vector: Decodable {
    let root_key_hex, enc_key_hex, room_id, token_hex, token_b64url: String
    let safety_code, base32, nonce_hex, plaintext_utf8, ciphertext_hex: String
}

enum Vectors {
    static let all: [Vector] = {
        let url = Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Resources")!
        return try! JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
    }()
}

extension Data {
    init(hex: String) {
        var d = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            d.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self = d
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
