import Foundation

public struct AgendaEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public var calendar: String?
    public var title: String
    public var start: Date?
    public var end: Date?
    public var location: String?
    public var link: URL?
    public var declined: Bool

    public var allDay: Bool { start == nil }

    public init(
        id: String, calendar: String? = nil, title: String, start: Date?, end: Date?,
        location: String? = nil, link: URL? = nil, declined: Bool = false
    ) {
        self.id = id
        self.calendar = calendar
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.link = link
        self.declined = declined
    }
}

public enum AgendaListError: Error, Equatable, LocalizedError {
    case notJSON

    public var errorDescription: String? {
        switch self {
        case .notJSON: "a saída não é uma lista JSON de eventos"
        }
    }
}

public enum AgendaList {
    public enum Marker: Sendable, Equatable { case now, next }

    public static func parse(_ data: Data) throws -> [AgendaEvent] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw AgendaListError.notJSON
        }
        let events = array.compactMap { raw -> AgendaEvent? in
            guard let object = raw as? [String: Any],
                  let id = object["id"] as? String,
                  let title = object["title"] as? String
            else { return nil }
            let allDay = object["allDay"] as? Bool ?? false
            let start = allDay ? nil : (object["start"] as? String).flatMap(AlertList.date)
            let end = allDay ? nil : (object["end"] as? String).flatMap(AlertList.date)
            if !allDay, start == nil { return nil }
            let link = (object["link"] as? String).flatMap(URL.init(string:)).flatMap { url in
                ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? url : nil
            }
            return AgendaEvent(
                id: id,
                calendar: object["account"] as? String,
                title: title,
                start: start,
                end: end,
                location: object["location"] as? String,
                link: link,
                declined: object["response"] as? String == "declined"
            )
        }
        return events.sorted { a, b in
            if a.allDay != b.allDay { return a.allDay }
            return (a.start ?? .distantPast) < (b.start ?? .distantPast)
        }
    }

    public static func markers(_ events: [AgendaEvent], now: Date = Date()) -> [String: Marker] {
        var markers: [String: Marker] = [:]
        let timed = events.filter { !$0.allDay && !$0.declined }
        for event in timed {
            guard let start = event.start else { continue }
            if start <= now, (event.end ?? start) > now { markers[event.id] = .now }
        }
        let upcoming = timed.compactMap { event in event.start.map { (event.id, $0) } }.filter { $0.1 > now }
        if let next = upcoming.min(by: { $0.1 < $1.1 }) {
            markers[next.0] = .next
        }
        return markers
    }

    public static func remaining(_ events: [AgendaEvent], now: Date = Date()) -> Int {
        events.filter { event in
            guard !event.declined, let start = event.start else { return false }
            return (event.end ?? start) > now
        }.count
    }
}
