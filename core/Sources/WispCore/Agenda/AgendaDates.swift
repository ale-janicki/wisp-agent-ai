import Foundation

public struct AgendaDates: Sendable {
    public struct Parsed: Equatable, Sendable {
        public let date: Date
        public let dateOnly: Bool
    }

    public let timeZone: TimeZone

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public func parse(_ text: String) -> Parsed? {
        let text = Self.colonOffset(text.trimmingCharacters(in: .whitespaces))
        let offset = ISO8601DateFormatter()
        offset.formatOptions = [.withInternetDateTime]
        if let date = offset.date(from: text) { return Parsed(date: date, dateOnly: false) }
        offset.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = offset.date(from: text) { return Parsed(date: date, dateOnly: false) }
        for (format, dateOnly) in [("yyyy-MM-dd'T'HH:mm:ss", false), ("yyyy-MM-dd'T'HH:mm", false), ("yyyy-MM-dd HH:mm", false), ("yyyy-MM-dd", true)] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.calendar = calendar
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: text) { return Parsed(date: date, dateOnly: dateOnly) }
        }
        return nil
    }

    private static func colonOffset(_ text: String) -> String {
        let tail = Array(text.suffix(5))
        guard text.contains("T"), tail.count == 5, tail[0] == "+" || tail[0] == "-", tail.dropFirst().allSatisfy(\.isASCII),
              tail.dropFirst().allSatisfy(\.isNumber) else { return text }
        return String(text.dropLast(2)) + ":" + String(tail.suffix(2))
    }

    public func format(_ date: Date, dateOnly: Bool = false) -> String {
        if dateOnly {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    public func adding(days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(Double(days) * 86_400)
    }
}
