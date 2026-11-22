import Foundation

public enum AssistKind: String, Codable, Equatable, Sendable {
    case ask = "pergunte"
    case answer = "responda"
    case remember = "lembre"

    public var label: String {
        switch self {
        case .ask: "Pergunte"
        case .answer: "Responda"
        case .remember: "Lembre"
        }
    }
}

public struct AssistItem: Codable, Equatable, Identifiable, Sendable {
    public var kind: AssistKind
    public var text: String

    public var id: String { "\(kind.rawValue)-\(EntityDetector.key(text))" }

    public init(kind: AssistKind, text: String) {
        self.kind = kind
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case kind = "tipo"
        case text = "texto"
    }
}

public enum AssistReport {
    public static let maximumItems = 3
    public static let shownLimit = 6

    public static func parse(_ data: Data) -> [AssistItem] {
        struct Wire: Decodable {
            var items: [AssistItem]

            enum CodingKeys: String, CodingKey { case items = "itens" }
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return [] }
        return Array(wire.items.filter { !$0.text.isEmpty }.prefix(maximumItems))
    }

    public static func merge(_ fresh: [AssistItem], into shown: [AssistItem]) -> [AssistItem] {
        let known = Set(shown.map(\.id))
        let added = fresh.filter { !known.contains($0.id) }
        return Array((added + shown).prefix(shownLimit))
    }
}

public struct AssistGate: Equatable, Sendable {
    public static let defaultInterval = 40.0

    public var minimumInterval: Double
    private var lastStart: Double?
    private var lastFinalCount = -1
    public private(set) var inFlight = false

    public init(minimumInterval: Double = defaultInterval) {
        self.minimumInterval = minimumInterval
    }

    public func shouldRun(at now: Double, finalCount: Int) -> Bool {
        guard !inFlight, finalCount > 0, finalCount != lastFinalCount else { return false }
        if let lastStart, now - lastStart < minimumInterval { return false }
        return true
    }

    public mutating func started(at now: Double, finalCount: Int) {
        inFlight = true
        lastStart = now
        lastFinalCount = finalCount
    }

    public mutating func finished() {
        inFlight = false
    }
}

public enum AssistTranscript {
    public static let windowSeconds = 240.0
    public static let characterLimit = 6000

    public static func window(_ segments: [MeetingSegment], elapsed: Double) -> String {
        let recent = segments.filter { $0.isFinal && $0.start >= elapsed - windowSeconds }
        let text = recent.map { "[\(ElapsedFormat.clock($0.start))] \($0.speakerName): \($0.text)" }.joined(separator: "\n")
        return String(text.suffix(characterLimit))
    }
}

public struct ChecklistItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var done: Bool

    public init(id: String = UUID().uuidString, text: String, done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
    }
}

public struct PrepReport: Equatable, Sendable {
    public var checklist: [String]
    public var questions: [String]

    public static func parse(_ data: Data) -> PrepReport {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        func strings(_ key: String) -> [String] {
            (object?[key] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        }
        return PrepReport(checklist: strings("checklist"), questions: strings("perguntas"))
    }

    public var items: [ChecklistItem] {
        (checklist + questions.map { "Perguntar: \($0)" }).filter { !$0.isEmpty }.map { ChecklistItem(text: $0) }
    }
}

public struct MeetingEvent: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var start: String
    public var notes: String
    public var attendees: [String]

    public init(id: String, title: String, start: String, notes: String = "", attendees: [String] = []) {
        self.id = id
        self.title = title
        self.start = start
        self.notes = notes
        self.attendees = attendees
    }

    public static func parse(_ data: Data) -> [MeetingEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["events"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard row["allDay"] as? Bool != true, let id = row["id"] as? String, let title = row["title"] as? String, !title.isEmpty else { return nil }
            return MeetingEvent(
                id: id, title: title, start: row["start"] as? String ?? "", notes: row["notes"] as? String ?? "",
                attendees: row["attendees"] as? [String] ?? []
            )
        }
    }
}

public enum MeetingContext {
    public static let characterLimit = 6000

    public static func build(event: MeetingEvent?, description: String, checklist: [ChecklistItem], hits: [BrainHit]) -> String {
        var parts: [String] = []
        if let event {
            parts.append("Evento: \(event.title) (\(event.start))")
            if !event.attendees.isEmpty { parts.append("Participantes: \(event.attendees.joined(separator: ", "))") }
            if !event.notes.isEmpty { parts.append("Notas do evento: \(event.notes)") }
        }
        let typed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append("Descrição: \(typed)") }
        let pending = checklist.filter { !$0.done }.map { "- \($0.text)" }
        if !pending.isEmpty { parts.append("Checklist pendente:\n" + pending.joined(separator: "\n")) }
        if !hits.isEmpty {
            parts.append("Notas do brain:\n" + hits.map { "- \($0.title): \($0.snippet)" }.joined(separator: "\n"))
        }
        return String(parts.joined(separator: "\n\n").prefix(characterLimit))
    }
}
