import Foundation
import Testing
@testable import ImgShareCore

@MainActor
struct OutgoingQueueTests {
    @Test func failedItemStaysWithErrorAndRetryRemovesIt() async {
        let q = OutgoingQueue()
        q.enqueue(.text("zu lang"))
        await q.process { _, _ in throw ApiError.http(status: 413, code: nil) }
        #expect(q.items.count == 1)
        #expect(q.items[0].error == "Datei ist zu groß für den Server.")
        q.retry(q.items[0].id)
        #expect(q.items[0].error == nil)
        await q.process { _, _ in }
        #expect(q.items.isEmpty)
    }

    @Test func progressIsReported() async {
        let q = OutgoingQueue()
        q.enqueue(.image(Data([1]), fileName: "a.png"))
        let seen = LockedBox<Double>(0)
        await q.process { item, report in
            report(0.5)
            try await Task.sleep(for: .milliseconds(20))
            seen.set(q.items.first?.progress ?? -1)
        }
        #expect(seen.get() == 0.5)
        #expect(q.items.isEmpty)
    }

    @Test func fifoAndFailedItemsDoNotBlock() async {
        let q = OutgoingQueue()
        q.enqueue(.text("1")); q.enqueue(.text("2")); q.enqueue(.text("3"))
        var order: [String] = []
        await q.process { item, _ in
            guard case .text(let t) = item.kind else { return }
            order.append(t)
            if t == "2" { throw URLError(.timedOut) }
        }
        #expect(order == ["1", "2", "3"])
        #expect(q.items.count == 1 && q.items[0].error == "Der Server antwortet nicht.")
    }

    @Test func discardRemoves() {
        let q = OutgoingQueue()
        q.enqueue(.text("x"))
        q.discard(q.items[0].id)
        #expect(q.items.isEmpty)
    }
}
