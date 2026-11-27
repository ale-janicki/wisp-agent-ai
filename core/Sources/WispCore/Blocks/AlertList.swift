import Foundation

public enum AlertList {
    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for fractional in [true, false] {
            for offset in [Date.ISO8601FormatStyle.TimeZoneSeparator.colon, .omitted] {
                let style = Date.ISO8601FormatStyle(timeZoneSeparator: offset, includingFractionalSeconds: fractional)
                if let date = try? style.parse(trimmed) { return date }
            }
        }
        return nil
    }

    public static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "agora"
        case ..<3_600: return "\(Int(seconds / 60)) min"
        case ..<86_400: return "\(Int(seconds / 3_600)) h"
        default: return "\(Int(seconds / 86_400)) d"
        }
    }
}
