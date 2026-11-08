import Foundation

/// Tagestrenner im Chat: „Heute“, „Gestern“ oder ausgeschriebenes Datum.
public enum DayLabel {
    public static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Heute" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return "Gestern"
        }
        var style = Date.FormatStyle(date: .complete, time: .omitted, locale: Locale(identifier: "de_AT"), calendar: calendar)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
