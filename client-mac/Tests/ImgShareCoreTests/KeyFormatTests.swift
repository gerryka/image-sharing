import Foundation
import Testing
@testable import ImgShareCore

struct KeyFormatTests {
    @Test func formatsVector() {
        for v in Vectors.all {
            let s = KeyFormat.format(Data(hex: v.root_key_hex))
            #expect(s == v.base32)
            #expect(s.split(separator: "-").count == 13)
            #expect(s.split(separator: "-").allSatisfy { $0.count == 4 })
        }
    }

    @Test func roundTrip() {
        for _ in 0..<50 {
            let k = ChatKeys.generateRootKey()
            #expect(KeyFormat.parse(KeyFormat.format(k)) == k)
        }
    }

    @Test func parseIsLenient() {
        let v = Vectors.all[0]
        let key = Data(hex: v.root_key_hex)
        #expect(KeyFormat.parse(v.base32.lowercased()) == key)
        #expect(KeyFormat.parse(v.base32.replacingOccurrences(of: "-", with: " ")) == key)
        #expect(KeyFormat.parse(v.base32.replacingOccurrences(of: "-", with: "\n")) == key)
        // AAAQ-EAYE-... enthält O/I nicht; eigener Key mit O und I:
        let k2 = KeyFormat.parse(KeyFormat.format(Data(repeating: 0x73, count: 32)))!
        let s2 = KeyFormat.format(k2)
        let typed = s2.replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1")
        #expect(KeyFormat.parse(typed) == k2)
    }

    @Test func parseRejects() {
        let v = Vectors.all[0]
        #expect(KeyFormat.parse(nil) == nil)
        #expect(KeyFormat.parse("") == nil)
        #expect(KeyFormat.parse("   ") == nil)
        #expect(KeyFormat.parse(v.base32.replacingOccurrences(of: "AAAQ", with: "AAA8")) == nil)
        #expect(KeyFormat.parse("9" + v.base32.dropFirst()) == nil)
        #expect(KeyFormat.parse(String(v.base32.dropLast())) == nil)
        // Letztes Zeichen trägt 4 Restbits (52*5 = 260 = 256 + 4); "DYPQ" → "DYPR" setzt ein Restbit
        #expect(KeyFormat.parse(String(v.base32.dropLast()) + "R") == nil)
    }
}
