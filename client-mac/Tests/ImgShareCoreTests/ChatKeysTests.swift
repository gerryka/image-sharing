import CryptoKit
import Foundation
import Testing
@testable import ImgShareCore

struct ChatKeysTests {
    @Test func derivesVectors() throws {
        for v in Vectors.all {
            let k = try ChatKeys.derive(rootKey: Data(hex: v.root_key_hex))
            #expect(k.encKey.withUnsafeBytes { Data($0) }.hex == v.enc_key_hex)
            #expect(k.roomId == v.room_id)
            #expect(k.token.hex == v.token_hex)
            #expect(k.tokenBase64URL == v.token_b64url)
            #expect(k.safetyCode == v.safety_code)
        }
    }

    @Test func encryptsVectorWithFixedNonce() throws {
        for v in Vectors.all {
            let k = try ChatKeys.derive(rootKey: Data(hex: v.root_key_hex))
            let plain = Data(v.plaintext_utf8.utf8)
            let ct = try k.encrypt(plain, nonce: Data(hex: v.nonce_hex))
            #expect(ct.hex == v.ciphertext_hex)
            #expect(try k.decrypt(Data(hex: v.ciphertext_hex)) == plain)
        }
    }

    @Test func rejectsWrongKeyLength() {
        #expect(throws: CryptoError.invalidKeyLength) {
            try ChatKeys.derive(rootKey: Data(count: 31))
        }
    }

    @Test func rejectsShortCiphertext() throws {
        let k = try ChatKeys.derive(rootKey: ChatKeys.generateRootKey())
        #expect(throws: CryptoError.dataTooShort) { try k.decrypt(Data(count: 27)) }
    }

    @Test func tamperedCiphertextFails() throws {
        let k = try ChatKeys.derive(rootKey: ChatKeys.generateRootKey())
        var ct = try k.encrypt(Data("hallo".utf8))
        ct[14] ^= 0x01
        #expect(throws: CryptoError.authenticationFailed) { try k.decrypt(ct) }
    }

    @Test func randomRoundTrip() throws {
        let root = ChatKeys.generateRootKey()
        #expect(root.count == 32)
        let k = try ChatKeys.derive(rootKey: root)
        let x = Data("Grüße 👋".utf8)
        let a = try k.encrypt(x), b = try k.encrypt(x)
        #expect(a != b)
        #expect(try k.decrypt(a) == x)
    }
}
