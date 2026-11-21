import XCTest
@testable import WispCore

private final class FakeStore: AgendaStore, @unchecked Sendable {
    var eventsAccess = AgendaAccess.granted
    var remindersAccess = AgendaAccess.granted
    var grantsOnRequest = true
    var requested: [AgendaKind] = []
    var events: [NativeEvent] = []
    var reminders: [AgendaReminder] = []
    var lists = [
        AgendaCalendar(id: "c1", title: "Trabalho", source: "Google", kind: .events, writable: true),
        AgendaCalendar(id: "c2", title: "Feriados", source: "Subscribed", kind: .events, writable: false),
        AgendaCalendar(id: "r1", title: "Casa", source: "iCloud", kind: .reminders, writable: true),
    ]
    var rangeAsked: (Date, Date, String?)?
    var created: NewEvent?
    var changed: (EventRef, EventChanges, Bool)?
    var deleted: [(EventRef, Bool)] = []
    var hangOnRequest = false
    var createdReminder: NewReminder?
    var pendingAsked: Bool?

    func access(for kind: AgendaKind) -> AgendaAccess { kind == .events ? eventsAccess : remindersAccess }
    func requestAccess(for kind: AgendaKind) async -> Bool {
        requested.append(kind)
        if hangOnRequest { try? await Task.sleep(for: .seconds(30)) }
        return grantsOnRequest
    }
    func calendars(for kind: AgendaKind) -> [AgendaCalendar] { lists.filter { $0.kind == kind } }
    func events(from start: Date, to end: Date, calendarID: String?) throws -> [NativeEvent] {
        rangeAsked = (start, end, calendarID)
        return events
    }
    func event(ref: EventRef) throws -> NativeEvent {
        let matches = events.filter { $0.id == ref.id && (ref.start == nil || $0.start == ref.start) }
        guard let found = matches.first else { throw AgendaError("não achei o evento \(ref.id)") }
        return found
    }
    func createEvent(_ new: NewEvent) throws -> NativeEvent {
        created = new
        return NativeEvent(id: "new", calendar: "Trabalho", title: new.title, start: new.start, end: new.end, allDay: new.allDay,
                           location: new.location, notes: new.notes)
    }
    func updateEvent(ref: EventRef, _ changes: EventChanges, wholeSeries: Bool) throws -> NativeEvent {
        changed = (ref, changes, wholeSeries)
        return try event(ref: ref)
    }
    func deleteEvent(ref: EventRef, wholeSeries: Bool) throws { deleted.append((ref, wholeSeries)) }
    func reminders(pendingOnly: Bool, listID: String?) async throws -> [AgendaReminder] {
        pendingAsked = pendingOnly
        return reminders
    }
    func createReminder(_ new: NewReminder) throws -> AgendaReminder {
        createdReminder = new
        return AgendaReminder(id: "rem", list: "Casa", title: new.title, due: new.due, dueHasTime: new.dueHasTime)
    }
    func completeReminder(id: String) throws -> AgendaReminder {
        AgendaReminder(id: id, list: "Casa", title: "Pagar luz", completed: true)
    }
}

final class NativeAgendaTests: XCTestCase {
    private let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!
    private lazy var dates = AgendaDates(timeZone: saoPaulo)
    private lazy var noon = dates.parse("2026-11-19T12:00:00-03:00")!.date

    private func service(_ store: FakeStore, accessTimeout: TimeInterval = 60) -> AgendaService {
        let now = noon
        return AgendaService(store: store, timeZone: saoPaulo, accessTimeout: accessTimeout, now: { now })
    }

    private func object(_ outcome: AgendaOutcome) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any])
    }

    private func events(_ outcome: AgendaOutcome) throws -> [[String: Any]] {
        try XCTUnwrap(try object(outcome)["events"] as? [[String: Any]])
    }

    private func array(_ outcome: AgendaOutcome) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [[String: Any]])
    }

    func testTodayCoversTheLocalDay() async throws {
        let store = FakeStore()
        let outcome = await service(store).run(arguments: ["eventos", "--hoje"])
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(dates.format(store.rangeAsked!.0), "2026-11-19T00:00:00-03:00")
        XCTAssertEqual(dates.format(store.rangeAsked!.1), "2026-11-20T00:00:00-03:00")
    }

    func testWeekAndDefaultAreSevenDaysFromTodayStart() async {
        let store = FakeStore()
        for arguments in [["eventos", "--semana"], ["eventos"]] {
            _ = await service(store).run(arguments: arguments)
            XCTAssertEqual(dates.format(store.rangeAsked!.0), "2026-11-19T00:00:00-03:00")
            XCTAssertEqual(dates.format(store.rangeAsked!.1), "2026-11-26T00:00:00-03:00")
        }
    }

    func testExplicitRangeWithDateOnlyEndIncludesThatDay() async {
        let store = FakeStore()
        _ = await service(store).run(arguments: ["eventos", "--de", "2026-12-01", "--ate=2026-12-03"])
        XCTAssertEqual(dates.format(store.rangeAsked!.0), "2026-12-01T00:00:00-03:00")
        XCTAssertEqual(dates.format(store.rangeAsked!.1), "2026-12-04T00:00:00-03:00")
    }

    func testRangeEndingBeforeItStartsIsRefused() async {
        let outcome = await service(FakeStore()).run(arguments: ["eventos", "--de", "2026-12-05", "--ate", "2026-12-01T10:00:00-03:00"])
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertTrue(outcome.stderr.contains("--ate é antes de --de"))
    }

    func testEventJSONShapeUsesLocalOffsetAndDatesForAllDay() async throws {
        let store = FakeStore()
        store.events = [
            NativeEvent(id: "a", calendar: "Trabalho", title: "Reunião", start: noon, end: noon.addingTimeInterval(3600), allDay: false,
                        location: "Sala 2", attendees: ["Ana"]),
            NativeEvent(id: "b", calendar: "Feriados", title: "Natal", start: dates.parse("2026-12-25")!.date,
                        end: dates.parse("2026-12-25")!.date, allDay: true),
        ]
        let list = try events(await service(store).run(arguments: ["eventos", "--calendario", "trabalho"]))
        XCTAssertEqual(store.rangeAsked?.2, "c1")
        XCTAssertEqual(list[0]["start"] as? String, "2026-11-19T12:00:00-03:00")
        XCTAssertEqual(list[0]["end"] as? String, "2026-11-19T13:00:00-03:00")
        XCTAssertEqual(list[0]["location"] as? String, "Sala 2")
        XCTAssertEqual(list[0]["attendees"] as? [String], ["Ana"])
        XCTAssertEqual(list[0]["recorrente"] as? Bool, false)
        XCTAssertEqual(list[0]["id"] as? String, "a")
        XCTAssertTrue(list[0]["notes"] is NSNull)
        XCTAssertEqual(list[1]["start"] as? String, "2026-12-25")
        XCTAssertEqual(list[1]["allDay"] as? Bool, true)
    }

    func testUnknownCalendarListsTheAvailableOnes() async {
        let outcome = await service(FakeStore()).run(arguments: ["eventos", "--calendario", "Nada"])
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertTrue(outcome.stderr.contains("Disponíveis: Trabalho, Feriados"))
    }

    func testCreateEventParsesLocalTimesAndTargetsTheNamedCalendar() async throws {
        let store = FakeStore()
        let outcome = await service(store).run(arguments: ["criar-evento", "--titulo", "Dentista", "--inicio", "2026-11-20T14:30",
                                                           "--fim", "2026-11-20T15:30", "--local", "Centro", "--calendario", "Trabalho"])
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(dates.format(store.created!.start), "2026-11-20T14:30:00-03:00")
        XCTAssertEqual(store.created?.calendarID, "c1")
        XCTAssertEqual(store.created?.allDay, false)
        XCTAssertEqual(try object(outcome)["title"] as? String, "Dentista")
    }

    func testCreateEventWithOnlyDatesIsAllDay() async {
        let store = FakeStore()
        _ = await service(store).run(arguments: ["criar-evento", "--titulo", "Viagem", "--inicio", "2026-12-01", "--fim", "2026-12-03"])
        XCTAssertEqual(store.created?.allDay, true)
    }

    func testCreateEventRejectsBadDatesEndBeforeStartAndReadOnlyCalendars() async {
        let store = FakeStore()
        var outcome = await service(store).run(arguments: ["criar-evento", "--titulo", "x", "--inicio", "amanhã", "--fim", "2026-11-20"])
        XCTAssertTrue(outcome.stderr.contains("--inicio: data inválida"))
        outcome = await service(store).run(arguments: ["criar-evento", "--titulo", "x", "--inicio", "2026-11-20T10:00", "--fim", "2026-11-20T09:00"])
        XCTAssertTrue(outcome.stderr.contains("fim do evento é antes"))
        outcome = await service(store).run(arguments: ["criar-evento", "--titulo", "x", "--inicio", "2026-11-20T10:00", "--fim", "2026-11-20T11:00",
                                                       "--calendario", "Feriados"])
        XCTAssertTrue(outcome.stderr.contains("somente leitura"))
        XCTAssertNil(store.created)
    }

    func testMissingRequiredOptionIsAUsageError() async {
        let outcome = await service(FakeStore()).run(arguments: ["criar-evento", "--titulo", "x"])
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertTrue(outcome.stderr.contains("falta --inicio"))
    }

    func testEditEventSendsOnlyWhatChanged() async {
        let store = FakeStore()
        store.events = [NativeEvent(id: "a", calendar: "Trabalho", title: "Reunião", start: noon, end: noon.addingTimeInterval(4 * 3600), allDay: false)]
        let outcome = await service(store).run(arguments: ["editar-evento", "a", "--titulo", "Reunião com o Rui", "--inicio", "2026-11-19T15:00:00-03:00"])
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(store.changed?.0, EventRef(id: "a"))
        XCTAssertEqual(store.changed?.1.title, "Reunião com o Rui")
        XCTAssertNil(store.changed?.1.location)
        XCTAssertNil(store.changed?.1.end)
    }

    func testEditWithNothingToChangeFails() async {
        let outcome = await service(FakeStore()).run(arguments: ["editar-evento", "a"])
        XCTAssertTrue(outcome.stderr.contains("nada para mudar"))
    }

    func testDeleteWithoutAttendeesDeletes() async throws {
        let store = FakeStore()
        store.events = [NativeEvent(id: "a", calendar: "Trabalho", title: "Sozinho", start: noon, end: noon, allDay: false)]
        let outcome = await service(store).run(arguments: ["apagar-evento", "a"])
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(store.deleted.map(\.0), [EventRef(id: "a")])
        XCTAssertEqual(try object(outcome)["deleted"] as? String, "a")
    }

    func testDeleteRefusesAnEventWithAttendeesUntilConfirmed() async {
        let store = FakeStore()
        store.events = [NativeEvent(id: "a", calendar: "Trabalho", title: "Planning", start: noon, end: noon, allDay: false, attendees: ["Ana", "Rui"])]
        let refused = await service(store).run(arguments: ["apagar-evento", "a"])
        XCTAssertEqual(refused.exitCode, AgendaError.needsConfirmationExitCode)
        XCTAssertTrue(refused.stdout.isEmpty)
        XCTAssertTrue(refused.stderr.contains("2 convidado(s)"))
        XCTAssertTrue(refused.stderr.contains("Pergunte ao usuário"))
        XCTAssertTrue(refused.stderr.contains("--confirmo"))
        XCTAssertTrue(store.deleted.isEmpty)
        let confirmed = await service(store).run(arguments: ["apagar-evento", "a", "--confirmo"])
        XCTAssertEqual(confirmed.exitCode, 0)
        XCTAssertEqual(store.deleted.count, 1)
    }

    func testRemindersPendingFlagAndJSONShape() async throws {
        let store = FakeStore()
        store.reminders = [
            AgendaReminder(id: "r", list: "Casa", title: "Pagar luz", due: noon, dueHasTime: true),
            AgendaReminder(id: "s", list: "Casa", title: "Mercado", due: dates.parse("2026-11-21")!.date, dueHasTime: false),
            AgendaReminder(id: "t", list: "Casa", title: "Sem data"),
        ]
        let list = try array(await service(store).run(arguments: ["lembretes", "--pendentes", "--lista", "casa"]))
        XCTAssertEqual(store.pendingAsked, true)
        XCTAssertEqual(list[0]["due"] as? String, "2026-11-19T12:00:00-03:00")
        XCTAssertEqual(list[1]["due"] as? String, "2026-11-21")
        XCTAssertTrue(list[2]["due"] is NSNull)
        XCTAssertEqual(list[0]["completed"] as? Bool, false)
    }

    func testCreateReminderWithTimeAndWithDateOnly() async {
        let store = FakeStore()
        _ = await service(store).run(arguments: ["criar-lembrete", "--titulo", "Ligar", "--quando", "2026-11-20T09:00", "--lista", "Casa"])
        XCTAssertEqual(store.createdReminder?.dueHasTime, true)
        XCTAssertEqual(store.createdReminder?.listID, "r1")
        _ = await service(store).run(arguments: ["criar-lembrete", "--titulo", "Comprar", "--quando", "2026-11-22"])
        XCTAssertEqual(store.createdReminder?.dueHasTime, false)
        _ = await service(store).run(arguments: ["criar-lembrete", "--titulo", "Qualquer hora"])
        XCTAssertNil(store.createdReminder?.due)
    }

    func testCompleteReminder() async throws {
        let outcome = await service(FakeStore()).run(arguments: ["concluir-lembrete", "rem1"])
        XCTAssertEqual(try object(outcome)["completed"] as? Bool, true)
    }

    func testCalendarsListBothKinds() async throws {
        let list = try array(await service(FakeStore()).run(arguments: ["calendarios"]))
        XCTAssertEqual(list.map { $0["title"] as? String }, ["Trabalho", "Feriados", "Casa"])
        XCTAssertEqual(list.map { $0["kind"] as? String }, ["eventos", "eventos", "lembretes"])
        XCTAssertEqual(list[1]["writable"] as? Bool, false)
    }

    func testDeniedPermissionIsOnePortugueseLineWithTheWayToGrantIt() async {
        for access in [AgendaAccess.denied, .restricted, .writeOnly] {
            let store = FakeStore()
            store.eventsAccess = access
            let outcome = await service(store).run(arguments: ["eventos", "--hoje"])
            XCTAssertEqual(outcome.exitCode, AgendaError.permissionExitCode)
            XCTAssertTrue(outcome.stdout.isEmpty)
            XCTAssertTrue(outcome.stderr.contains("Privacidade e Segurança > Calendários"))
            XCTAssertFalse(outcome.stderr.contains("\n"))
            XCTAssertTrue(store.requested.isEmpty, "a refused permission is never asked again")
        }
    }

    func testRefusedWritesSayTheyCannotChangeAndWriteOnlySaysSo() async {
        let writes = [["criar-evento", "--titulo", "X", "--inicio", "2026-11-20T10:00", "--fim", "2026-11-20T11:00"],
                      ["editar-evento", "e1", "--titulo", "X"], ["apagar-evento", "e1"]]
        for arguments in writes {
            let store = FakeStore()
            store.eventsAccess = .denied
            let outcome = await service(store).run(arguments: arguments)
            XCTAssertEqual(outcome.exitCode, AgendaError.permissionExitCode)
            XCTAssertTrue(outcome.stderr.contains("sem permissão para alterar Calendários"), outcome.stderr)
            XCTAssertFalse(outcome.stderr.contains("para ler"))
        }
        for arguments in [["criar-lembrete", "--titulo", "X"], ["concluir-lembrete", "r1"]] {
            let store = FakeStore()
            store.remindersAccess = .denied
            let outcome = await service(store).run(arguments: arguments)
            XCTAssertTrue(outcome.stderr.contains("sem permissão para alterar Lembretes"), outcome.stderr)
        }
        let writeOnly = FakeStore()
        writeOnly.eventsAccess = .writeOnly
        let read = await service(writeOnly).run(arguments: ["eventos", "--hoje"])
        XCTAssertTrue(read.stderr.contains("só tem acesso de escrita a Calendários e precisa de acesso total para ler"), read.stderr)
        let write = await service(writeOnly).run(arguments: ["apagar-evento", "e1"])
        XCTAssertTrue(write.stderr.contains("só tem acesso de escrita a Calendários e precisa de acesso total para alterar"), write.stderr)
        XCTAssertEqual(write.exitCode, AgendaError.permissionExitCode)
    }

    func testReminderDueComponentsFollowTheGivenTimeZoneNotTheSystemOne() {
        let due = dates.parse("2026-11-19T23:30:00-03:00")!.date
        func components(_ zone: String) -> DateComponents {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            return EventKitStore.dueComponents(due, hasTime: true, calendar: calendar)
        }
        XCTAssertEqual([components("America/Sao_Paulo").day, components("America/Sao_Paulo").hour], [19, 23])
        XCTAssertEqual([components("Asia/Tokyo").day, components("Asia/Tokyo").hour], [20, 11])
        var dateOnly = Calendar(identifier: .gregorian)
        dateOnly.timeZone = saoPaulo
        XCTAssertNil(EventKitStore.dueComponents(due, hasTime: false, calendar: dateOnly).hour)
    }

    func testRemindersPermissionNamesReminders() async {
        let store = FakeStore()
        store.remindersAccess = .denied
        let outcome = await service(store).run(arguments: ["lembretes"])
        XCTAssertEqual(outcome.exitCode, AgendaError.permissionExitCode)
        XCTAssertTrue(outcome.stderr.contains("Privacidade e Segurança > Lembretes"))
    }

    func testNotDeterminedAsksOnceAndContinuesWhenGranted() async {
        let store = FakeStore()
        store.eventsAccess = .notDetermined
        let outcome = await service(store).run(arguments: ["eventos", "--hoje"])
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(store.requested, [.events])
    }

    func testNotDeterminedAnsweredNoFailsWithPermissionError() async {
        let store = FakeStore()
        store.eventsAccess = .notDetermined
        store.grantsOnRequest = false
        let outcome = await service(store).run(arguments: ["eventos", "--hoje"])
        XCTAssertEqual(outcome.exitCode, AgendaError.permissionExitCode)
        XCTAssertTrue(outcome.stderr.contains("Calendários"))
    }

    func testCalendarsStillListsTheKindThatWasGranted() async throws {
        let store = FakeStore()
        store.remindersAccess = .denied
        let list = try array(await service(store).run(arguments: ["calendarios"]))
        XCTAssertEqual(list.count, 2)
    }

    func testUnknownCommandShowsUsage() async {
        let outcome = await service(FakeStore()).run(arguments: ["voar"])
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertTrue(outcome.stderr.contains("comando desconhecido: voar"))
        let none = await service(FakeStore()).run(arguments: [])
        XCTAssertTrue(none.stderr.contains("uso: wisp agenda"))
    }

    private func weekly() -> (FakeStore, Date, Date) {
        let first = noon
        let second = dates.adding(days: 7, to: noon)
        let store = FakeStore()
        store.events = [
            NativeEvent(id: "w", calendar: "Trabalho", title: "Semanal", start: first, end: first.addingTimeInterval(3600), allDay: false, recurring: true),
            NativeEvent(id: "w", calendar: "Trabalho", title: "Semanal", start: second, end: second.addingTimeInterval(3600), allDay: false, recurring: true),
        ]
        return (store, first, second)
    }

    func testRecurringEventsExposeAnOccurrenceKey() async throws {
        let (store, _, _) = weekly()
        let list = try events(await service(store).run(arguments: ["eventos"]))
        XCTAssertEqual(list[0]["recorrente"] as? Bool, true)
        XCTAssertEqual(list[0]["id"] as? String, "w@2026-11-19T12:00:00-03:00")
        XCTAssertEqual(list[1]["id"] as? String, "w@2026-11-26T12:00:00-03:00")
    }

    func testRecurringEditAndDeleteWithoutAnOccurrenceAreRefused() async {
        let (store, _, _) = weekly()
        let edit = await service(store).run(arguments: ["editar-evento", "w", "--titulo", "Novo"])
        let delete = await service(store).run(arguments: ["apagar-evento", "w"])
        for outcome in [edit, delete] {
            XCTAssertEqual(outcome.exitCode, 1)
            XCTAssertTrue(outcome.stderr.contains("se repete"))
            XCTAssertTrue(outcome.stderr.contains("--serie"))
        }
        XCTAssertNil(store.changed)
        XCTAssertTrue(store.deleted.isEmpty)
    }

    func testRecurringDeleteOfOneOccurrenceTouchesOnlyThatOne() async {
        let (store, _, second) = weekly()
        let outcome = await service(store).run(arguments: ["apagar-evento", "w@2026-11-26T12:00:00-03:00"])
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(store.deleted.count, 1)
        XCTAssertEqual(store.deleted[0].0, EventRef(id: "w", start: second))
        XCTAssertFalse(store.deleted[0].1)
    }

    func testRecurringEditOfOneOccurrenceAndOfTheSeries() async {
        let (store, first, _) = weekly()
        _ = await service(store).run(arguments: ["editar-evento", "w@2026-11-19T12:00:00-03:00", "--local", "Sala 3"])
        XCTAssertEqual(store.changed?.0, EventRef(id: "w", start: first))
        XCTAssertEqual(store.changed?.2, false)
        _ = await service(store).run(arguments: ["editar-evento", "w", "--serie", "--local", "Sala 4"])
        XCTAssertEqual(store.changed?.0, EventRef(id: "w"))
        XCTAssertEqual(store.changed?.2, true)
        _ = await service(store).run(arguments: ["apagar-evento", "w", "--serie"])
        XCTAssertEqual(store.deleted.last?.1, true)
    }

    func testAnIdWithAnAtSignThatIsNotATimeStaysWhole() async {
        let store = FakeStore()
        store.events = [NativeEvent(id: "abc@google.com", calendar: "Trabalho", title: "x", start: noon, end: noon, allDay: false)]
        let outcome = await service(store).run(arguments: ["apagar-evento", "abc@google.com"])
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(store.deleted.first?.0, EventRef(id: "abc@google.com"))
    }

    func testEditChecksTheEndAgainstTheExistingStart() async {
        let store = FakeStore()
        store.events = [NativeEvent(id: "a", calendar: "Trabalho", title: "x", start: noon, end: noon.addingTimeInterval(3600), allDay: false)]
        let outcome = await service(store).run(arguments: ["editar-evento", "a", "--fim", "2026-11-19T11:00:00-03:00"])
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertTrue(outcome.stderr.contains("antes do início"))
        XCTAssertNil(store.changed)
        let same = await service(store).run(arguments: ["editar-evento", "a", "--fim", "2026-11-19T12:00:00-03:00"])
        XCTAssertEqual(same.exitCode, 1)
    }

    func testEditingAnEventWithGuestsNeedsTheConfirmationFlag() async {
        let store = FakeStore()
        store.events = [NativeEvent(id: "a", calendar: "Trabalho", title: "Planning", start: noon, end: noon.addingTimeInterval(3600), allDay: false, attendees: ["Ana"])]
        let refused = await service(store).run(arguments: ["editar-evento", "a", "--titulo", "Outro"])
        XCTAssertEqual(refused.exitCode, AgendaError.needsConfirmationExitCode)
        XCTAssertNil(store.changed)
        let confirmed = await service(store).run(arguments: ["editar-evento", "a", "--titulo", "Outro", "--confirmo"])
        XCTAssertEqual(confirmed.exitCode, 0)
        XCTAssertNotNil(store.changed)
    }

    func testEventRangesAreClampedTo92DaysAndFlaggedTruncated() async throws {
        let store = FakeStore()
        let outcome = await service(store).run(arguments: ["eventos", "--de", "2026-01-01", "--ate", "2026-12-31"])
        XCTAssertEqual(dates.format(store.rangeAsked!.1), "2026-04-03T00:00:00-03:00")
        XCTAssertEqual(try object(outcome)["truncado"] as? Bool, true)
        let normal = await service(store).run(arguments: ["eventos", "--hoje"])
        XCTAssertEqual(try object(normal)["truncado"] as? Bool, false)
    }

    func testEventListsAreCappedAt200() async throws {
        let store = FakeStore()
        store.events = (0..<250).map { NativeEvent(id: "e\($0)", calendar: "Trabalho", title: "x", start: noon, end: noon, allDay: false) }
        let outcome = await service(store).run(arguments: ["eventos"])
        XCTAssertEqual(try events(outcome).count, 200)
        XCTAssertEqual(try object(outcome)["truncado"] as? Bool, true)
    }

    func testAllRemindersKeepsPendingAndOnlyRecentlyCompleted() async throws {
        let store = FakeStore()
        store.reminders = [
            AgendaReminder(id: "p", list: "Casa", title: "pendente"),
            AgendaReminder(id: "n", list: "Casa", title: "feito ontem", completed: true, completedAt: dates.adding(days: -1, to: noon)),
            AgendaReminder(id: "o", list: "Casa", title: "feito há 60 dias", completed: true, completedAt: dates.adding(days: -60, to: noon)),
            AgendaReminder(id: "u", list: "Casa", title: "feito sem data", completed: true),
        ]
        let list = try array(await service(store).run(arguments: ["lembretes"]))
        XCTAssertEqual(list.map { $0["id"] as? String }, ["p", "n"])
    }

    func testAPermissionPromptThatNeverAnswersTimesOutWithExit2() async {
        let store = FakeStore()
        store.eventsAccess = .notDetermined
        store.hangOnRequest = true
        let outcome = await service(store, accessTimeout: 0.1).run(arguments: ["eventos", "--hoje"])
        XCTAssertEqual(outcome.exitCode, AgendaError.permissionExitCode)
        XCTAssertTrue(outcome.stderr.contains("abra o Wisp no Mac e permita a agenda em Ajustes > Agenda"))
    }

    func testPermissionCommandReportsStateAndOnlyAsksWhenToldTo() async throws {
        let store = FakeStore()
        store.eventsAccess = .notDetermined
        store.remindersAccess = .denied
        let report = try object(await service(store).run(arguments: ["permissao"]))
        XCTAssertEqual(report["eventos"] as? String, "notDetermined")
        XCTAssertEqual(report["lembretes"] as? String, "denied")
        XCTAssertTrue(store.requested.isEmpty)
        _ = await service(store).run(arguments: ["permissao", "--pedir"])
        XCTAssertEqual(store.requested, [.events])
    }

    func testDatesAcceptOffsetsWithoutAColon() {
        XCTAssertEqual(dates.parse("2026-11-19T12:00:00-0300")?.date, dates.parse("2026-11-19T12:00:00-03:00")?.date)
        XCTAssertEqual(dates.parse("2026-11-19T12:00:00+0530")?.date, dates.parse("2026-11-19T12:00:00+05:30")?.date)
    }

    func testDatesParseOffsetLocalAndDateOnlyForms() {
        XCTAssertEqual(dates.parse("2026-11-19T12:00:00Z")?.date, dates.parse("2026-11-19T09:00:00-03:00")?.date)
        XCTAssertEqual(dates.parse("2026-11-19T09:00")?.date, dates.parse("2026-11-19T09:00:00-03:00")?.date)
        XCTAssertEqual(dates.parse("2026-11-19")?.dateOnly, true)
        XCTAssertNil(dates.parse("2026-13-40"))
        XCTAssertNil(dates.parse("hoje"))
    }
}
