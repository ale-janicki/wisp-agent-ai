import Foundation

public struct AlertItem: Identifiable, Equatable, Sendable {
    public enum Level: Sendable, Equatable { case red, yellow }

    public let id: String
    public var level: Level
    public var text: String
    public var openedAt: Date?
    public var front: String?
    public var theme: String?

    public init(id: String, level: Level, text: String, openedAt: Date?, front: String? = nil, theme: String? = nil) {
        self.id = id
        self.level = level
        self.text = text
        self.openedAt = openedAt
        self.front = front
        self.theme = theme
    }
}

public enum AlertListError: Error, Equatable, LocalizedError {
    case notJSON

    public var errorDescription: String? {
        switch self {
        case .notJSON: "a saída não é uma lista JSON de alertas"
        }
    }
}

public enum AlertList {
    public static func parse(_ data: Data) throws -> [AlertItem] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw AlertListError.notJSON
        }
        let items = array.compactMap { raw -> AlertItem? in
            guard let object = raw as? [String: Any],
                  let id = object["chave"] as? String,
                  let text = object["texto"] as? String
            else { return nil }
            let stamp = (object["aberto_ts"] as? String) ?? (object["ts"] as? String)
            return AlertItem(
                id: id,
                level: object["nivel"] as? String == "red" ? .red : .yellow,
                text: text,
                openedAt: stamp.flatMap(Self.date),
                front: object["frente"] as? String,
                theme: object["tema"] as? String
            )
        }
        return items.sorted { a, b in
            if a.level != b.level { return a.level == .red }
            return (a.openedAt ?? .distantPast) > (b.openedAt ?? .distantPast)
        }
    }

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
