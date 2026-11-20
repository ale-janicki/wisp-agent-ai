import Foundation

public struct AgendaOutcome: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

public struct AgendaService: Sendable {
    public static let defaultWindowDays = 7
    public static let maxWindowDays = 92
    public static let maxEvents = 200
    public static let completedReminderDays = 30
    public static let accessTimeout: TimeInterval = 60

    private let store: any AgendaStore
    private let dates: AgendaDates
    private let now: @Sendable () -> Date
    private let accessTimeout: TimeInterval

    public init(store: any AgendaStore, timeZone: TimeZone = .current, accessTimeout: TimeInterval = AgendaService.accessTimeout,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.accessTimeout = accessTimeout
        self.dates = AgendaDates(timeZone: timeZone)
        self.now = now
    }

    public func run(arguments: [String]) async -> AgendaOutcome {
        do {
            let command = try AgendaCommand.parse(arguments)
            return AgendaOutcome(stdout: try await execute(command), stderr: "", exitCode: 0)
        } catch let error as AgendaError {
            return AgendaOutcome(stdout: "", stderr: error.message, exitCode: error.exitCode)
        } catch {
            return AgendaOutcome(stdout: "", stderr: error.localizedDescription, exitCode: 1)
        }
    }

    private func execute(_ command: AgendaCommand) async throws -> String {
        switch command {
        case .events(let from, let to, let today, let week, let calendar):
            try await ensureAccess(.events)
            let range = try eventRange(from: from, to: to, today: today, week: week)
            let id = try calendarID(named: calendar, kind: .events)
            let found = try store.events(from: range.start, to: range.end, calendarID: id)
            let truncated = range.clamped || found.count > Self.maxEvents
            return try json(["events": found.prefix(Self.maxEvents).map(eventJSON), "truncado": truncated])
        case .createEvent(let title, let start, let end, let location, let notes, let calendar):
            try await ensureAccess(.events, writing: true)
            let begin = try parse(start, "--inicio"), finish = try parse(end, "--fim")
            guard finish.date >= begin.date else { throw AgendaError("o fim do evento é antes do início") }
            let id = try calendarID(named: calendar, kind: .events, needsWrite: true)
            let new = NewEvent(title: title, start: begin.date, end: finish.date, allDay: begin.dateOnly && finish.dateOnly,
                               location: location, notes: notes, calendarID: id)
            return try json(eventJSON(try store.createEvent(new)))
        case .editEvent(let id, let title, let start, let end, let location, let notes, let calendar, let series, let confirmed):
            try await ensureAccess(.events, writing: true)
            let begin = try start.map { try parse($0, "--inicio") }, finish = try end.map { try parse($0, "--fim") }
            let changes = EventChanges(title: title, start: begin?.date, end: finish?.date,
                                       allDay: (begin != nil && finish != nil) ? begin!.dateOnly && finish!.dateOnly : nil,
                                       location: location, notes: notes,
                                       calendarID: try calendarID(named: calendar, kind: .events, needsWrite: true))
            guard !changes.isEmpty else { throw AgendaError("editar-evento: nada para mudar") }
            let (ref, event) = try resolve(id, series: series)
            let newStart = changes.start ?? event.start, newEnd = changes.end ?? event.end
            let allDay = changes.allDay ?? event.allDay
            guard newEnd > newStart || (allDay && newEnd == newStart) else { throw AgendaError("o fim do evento ficaria antes do início") }
            try requireConfirmation(event, confirmed: confirmed, action: "mudar")
            return try json(eventJSON(try store.updateEvent(ref: ref, changes, wholeSeries: series)))
        case .deleteEvent(let id, let series, let confirmed):
            try await ensureAccess(.events, writing: true)
            let (ref, event) = try resolve(id, series: series)
            try requireConfirmation(event, confirmed: confirmed, action: "apagar")
            try store.deleteEvent(ref: ref, wholeSeries: series)
            return try json(["deleted": id])
        case .reminders(let pendingOnly, let list):
            try await ensureAccess(.reminders)
            let id = try calendarID(named: list, kind: .reminders)
            let cutoff = dates.adding(days: -Self.completedReminderDays, to: now())
            let found = try await store.reminders(pendingOnly: pendingOnly, listID: id)
            let recent = found.filter { !$0.completed || ($0.completedAt.map { $0 >= cutoff } ?? false) }
            return try json(recent.map(reminderJSON))
        case .createReminder(let title, let when, let list):
            try await ensureAccess(.reminders, writing: true)
            let due = try when.map { try parse($0, "--quando") }
            let id = try calendarID(named: list, kind: .reminders, needsWrite: true)
            let new = NewReminder(title: title, due: due?.date, dueHasTime: !(due?.dateOnly ?? false), listID: id)
            return try json(reminderJSON(try store.createReminder(new)))
        case .completeReminder(let id):
            try await ensureAccess(.reminders, writing: true)
            return try json(reminderJSON(try store.completeReminder(id: id)))
        case .access(let request):
            var report: [String: String] = [:]
            for kind in [AgendaKind.events, .reminders] {
                if request, store.access(for: kind) == .notDetermined { _ = await requestWithDeadline(kind) }
                report[kind.rawValue] = Self.label(store.access(for: kind))
            }
            return try json(report)
        case .calendars:
            var all: [AgendaCalendar] = []
            var failure: AgendaError?
            for kind in [AgendaKind.events, .reminders] {
                do {
                    try await ensureAccess(kind)
                    all += store.calendars(for: kind)
                } catch let error as AgendaError {
                    failure = failure ?? error
                }
            }
            if all.isEmpty, let failure { throw failure }
            return try json(all.map(calendarJSON))
        }
    }

    private func ensureAccess(_ kind: AgendaKind, writing: Bool = false) async throws {
        let label = kind == .events ? "Calendários" : "Lembretes"
        switch store.access(for: kind) {
        case .granted:
            return
        case .notDetermined:
            switch await requestWithDeadline(kind) {
            case true?: return
            case false?: throw denied(label, access: .denied, writing: writing)
            case nil:
                throw AgendaError("o macOS não respondeu ao pedido de acesso a \(label) em \(Int(accessTimeout)) s: abra o Wisp no Mac e permita a agenda em Ajustes > Agenda.",
                                  exitCode: AgendaError.permissionExitCode)
            }
        case let refused:
            throw denied(label, access: refused, writing: writing)
        }
    }

    private func requestWithDeadline(_ kind: AgendaKind) async -> Bool? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let store = store
            let timeout = Task { [accessTimeout] in
                guard (try? await Task.sleep(for: .seconds(accessTimeout))) != nil else { return }
                once.resume(nil)
            }
            Task {
                once.resume(await store.requestAccess(for: kind))
                timeout.cancel()
            }
        }
    }

    private static func label(_ access: AgendaAccess) -> String {
        switch access {
        case .granted: "granted"
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .writeOnly: "writeOnly"
        }
    }

    private func resolve(_ raw: String, series: Bool) throws -> (EventRef, NativeEvent) {
        let ref = reference(raw)
        let event = try store.event(ref: ref)
        if event.recurring, ref.start == nil, !series {
            throw AgendaError("este evento se repete. Use o id com horário que o comando eventos mostra (\(event.id)@<início>) para mexer só nessa ocorrência, ou --serie para mexer nela e nas próximas.")
        }
        return (ref, event)
    }

    private func reference(_ raw: String) -> EventRef {
        guard let at = raw.lastIndex(of: "@"), let parsed = dates.parse(String(raw[raw.index(after: at)...])), !parsed.dateOnly else {
            return EventRef(id: raw)
        }
        return EventRef(id: String(raw[..<at]), start: parsed.date)
    }

    private func requireConfirmation(_ event: NativeEvent, confirmed: Bool, action: String) throws {
        guard !event.attendees.isEmpty, !confirmed else { return }
        throw AgendaError("este evento tem \(event.attendees.count) convidado(s) e \(action) avisa todos eles. Pergunte ao usuário se pode \(action) \"\(event.title)\" e só depois que ele disser sim repita o comando com --confirmo.",
                          exitCode: AgendaError.needsConfirmationExitCode)
    }

    private func denied(_ label: String, access: AgendaAccess, writing: Bool) -> AgendaError {
        let problem = access == .writeOnly
            ? "o Wisp só tem acesso de escrita a \(label) e precisa de acesso total para \(writing ? "alterar" : "ler")"
            : "sem permissão para \(writing ? "alterar" : "ler") \(label)"
        return AgendaError("\(problem). Abra Ajustes do Sistema > Privacidade e Segurança > \(label), ligue o Wisp (ou o wisp-agenda) com acesso total e tente de novo.",
                           exitCode: AgendaError.permissionExitCode)
    }

    private func eventRange(from: String?, to: String?, today: Bool, week: Bool) throws -> (start: Date, end: Date, clamped: Bool) {
        let todayStart = dates.startOfDay(now())
        if today { return (todayStart, dates.adding(days: 1, to: todayStart), false) }
        if week { return (todayStart, dates.adding(days: Self.defaultWindowDays, to: todayStart), false) }
        let start = try from.map { try parse($0, "--de").date } ?? todayStart
        let end: Date
        if let to {
            let parsed = try parse(to, "--ate")
            end = parsed.dateOnly ? dates.adding(days: 1, to: parsed.date) : parsed.date
        } else {
            end = dates.adding(days: Self.defaultWindowDays, to: start)
        }
        guard end > start else { throw AgendaError("--ate é antes de --de") }
        let limit = dates.adding(days: Self.maxWindowDays, to: start)
        return end > limit ? (start, limit, true) : (start, end, false)
    }

    private func parse(_ text: String, _ name: String) throws -> AgendaDates.Parsed {
        guard let parsed = dates.parse(text) else {
            throw AgendaError("\(name): data inválida \"\(text)\"; use ISO 8601, como 2026-11-19T14:30:00-03:00, 2026-11-19T14:30 ou 2026-11-19")
        }
        return parsed
    }

    private func calendarID(named name: String?, kind: AgendaKind, needsWrite: Bool = false) throws -> String? {
        guard let name else { return nil }
        let all = store.calendars(for: kind)
        let matches = all.filter { $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard let match = matches.first else {
            let known = all.map(\.title).joined(separator: ", ")
            throw AgendaError("não achei \(kind == .events ? "o calendário" : "a lista") \"\(name)\". Disponíveis: \(known)")
        }
        guard matches.count == 1 else {
            throw AgendaError("há mais de um com o nome \"\(name)\" (\(matches.map(\.source).joined(separator: ", "))); use o nome de outro")
        }
        if needsWrite, !match.writable { throw AgendaError("\"\(name)\" é somente leitura") }
        return match.id
    }

    private func eventJSON(_ event: NativeEvent) -> [String: Any] {
        [
            "id": event.recurring ? "\(event.id)@\(dates.format(event.start))" : event.id, "calendar": event.calendar, "title": event.title, "allDay": event.allDay,
            "start": dates.format(event.start, dateOnly: event.allDay), "end": dates.format(event.end, dateOnly: event.allDay),
            "location": event.location ?? NSNull(), "notes": event.notes ?? NSNull(), "attendees": event.attendees,
            "recorrente": event.recurring,
        ]
    }

    private func reminderJSON(_ reminder: AgendaReminder) -> [String: Any] {
        [
            "id": reminder.id, "list": reminder.list, "title": reminder.title, "completed": reminder.completed,
            "due": reminder.due.map { dates.format($0, dateOnly: !reminder.dueHasTime) } ?? NSNull(),
            "notes": reminder.notes ?? NSNull(),
        ]
    }

    private func calendarJSON(_ calendar: AgendaCalendar) -> [String: Any] {
        ["id": calendar.id, "title": calendar.title, "source": calendar.source, "kind": calendar.kind.rawValue, "writable": calendar.writable]
    }

    private func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool?, Never>?

    init(_ continuation: CheckedContinuation<Bool?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
