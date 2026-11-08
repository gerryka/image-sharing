import Foundation
import Testing
@testable import ImgShareCore

struct ModelsTests {
    func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, ms: Int = 0) -> Date {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        c.nanosecond = ms * 1_000_000
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    @Test func decodesDotNetPayload() throws {
        let json = #"{"v":1,"kind":"text","sender":"abc","sender_name":"Gerald","sent_at":"2026-11-07T10:00:00.1234567+00:00","text":"Hallo","image":null,"read_up_to":null}"#
        let p = try WireJSON.decoder().decode(Payload.self, from: Data(json.utf8))
        #expect(p.kind == "text")
        #expect(p.messageKind == .text)
        #expect(p.senderName == "Gerald")
        #expect(p.text == "Hallo")
        #expect(abs(p.sentAt.timeIntervalSince(utc(2026, 11, 7, 10, 0, 0, ms: 123))) < 0.001)
    }

    @Test func decodesOffsetTimestamp() throws {
        func sentAt(_ s: String) throws -> Date {
            let json = #"{"v":1,"kind":"read","sender":"a","sender_name":"b","sent_at":"\#(s)","read_up_to":4}"#
            return try WireJSON.decoder().decode(Payload.self, from: Data(json.utf8)).sentAt
        }
        #expect(try sentAt("2026-11-07T11:00:00+01:00") == sentAt("2026-11-07T10:00:00Z"))
        #expect(try sentAt("2026-11-07T10:00:00Z") == utc(2026, 11, 7, 10, 0, 0))
    }

    @Test func decodesGoServerPage() throws {
        let json = #"{"messages":[{"id":5,"server_ts":"2026-11-07T10:00:00Z","ciphertext":"AAEC"}],"has_more":true}"#
        let page = try WireJSON.decoder().decode(MessagesPage.self, from: Data(json.utf8))
        #expect(page.hasMore)
        #expect(page.messages == [EncryptedMessage(id: 5, serverTs: utc(2026, 11, 7, 10, 0, 0), ciphertext: "AAEC")])
    }

    @Test func unknownKindDecodes() throws {
        let json = #"{"v":1,"kind":"reaction","sender":"a","sender_name":"b","sent_at":"2026-11-07T10:00:00Z"}"#
        let p = try WireJSON.decoder().decode(Payload.self, from: Data(json.utf8))
        #expect(p.messageKind == nil)
    }

    @Test func encodesSnakeCase() throws {
        let p = Payload(kind: "text", sender: "d", senderName: "G", sentAt: utc(2026, 11, 7, 10, 0, 0, ms: 5), text: "x")
        let obj = try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(p)) as! [String: Any]
        #expect(Set(obj.keys) == ["v", "kind", "sender", "sender_name", "sent_at", "text"])
        let sent = obj["sent_at"] as! String
        #expect(sent == "2026-11-07T10:00:00.005Z")
    }

    @Test func imagePayloadRoundTrip() throws {
        let img = ImageInfo(blobId: "abc-1", mime: "image/png", filename: "a.png", size: 10, width: 2, height: 3)
        let p = Payload(kind: "image", sender: "d", senderName: "G", sentAt: Date(), image: img)
        let obj = try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(p)) as! [String: Any]
        let i = obj["image"] as! [String: Any]
        #expect(Set(i.keys) == ["blob_id", "mime", "filename", "size", "width", "height"])
        #expect(try WireJSON.decoder().decode(Payload.self, from: WireJSON.encoder().encode(p)).image == img)
    }
}
