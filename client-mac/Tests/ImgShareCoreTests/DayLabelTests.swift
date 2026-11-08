import Foundation
import Testing
@testable import ImgShareCore

struct DayLabelTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Vienna")!; return c }
    func date(_ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))! }

    @Test func labels() {
        let now = date(7, 9)
        #expect(DayLabel.text(for: date(7, 23), now: now, calendar: cal) == "Heute")
        #expect(DayLabel.text(for: date(6, 0), now: now, calendar: cal) == "Gestern")
        #expect(DayLabel.text(for: date(1), now: now, calendar: cal) == "Sonntag, 1. November 2026")
    }
}
