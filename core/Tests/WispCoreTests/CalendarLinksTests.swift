import XCTest
@testable import WispCore

final class CalendarLinksTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-cal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func event() -> CalEvent {
        var e = makeEvent("ev1", stamp(2026, 11, 23, 15, 30), stamp(2026, 11, 23, 16, 30), title: "Revisão da Sprint: Delfin!")
        e.attendees = [CalAttendee(name: "Ana"), CalAttendee(name: "Eu", isMe: true)]
        e.location = "https://meet.google.com/aaa-bbbb-ccc"
        return e
    }

    func testRecordingLinkRoundTripsThroughStoreAndSidecar() throws {
        let store = EventLinkStore(url: dir.appendingPathComponent("links.json"))
        let folder = dir.appendingPathComponent("2026-11-23_15-30-00", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = try store.recordRecording(event: event(), calendarTitle: "Moonxi", folder: folder, now: stamp(2026, 11, 23, 15, 31))
        XCTAssertEqual(link.title, "Revisão da Sprint: Delfin!")
        XCTAssertEqual(store.link(for: "ev1")?.recordingFolder, "2026-11-23_15-30-00")
        XCTAssertEqual(store.link(for: "ev1")?.calendar, "Moonxi")
        let sidecar = EventLinkStore.readSidecar(in: folder)
        XCTAssertEqual(sidecar?.title, "Revisão da Sprint: Delfin!")
        XCTAssertEqual(sidecar?.key, "ev1")
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testUpsertMergesNoteIntoExistingLink() throws {
        let store = EventLinkStore(url: dir.appendingPathComponent("nested/links.json"))
        try store.upsert(EventLink(key: "k", title: "T", eventStart: stamp(2026, 11, 23, 9), recordingFolder: "f1"))
        try store.upsert(EventLink(key: "k", title: "T2", eventStart: stamp(2026, 11, 23, 9), notePath: "meetings/x.md"))
        let merged = try XCTUnwrap(store.link(for: "k"))
        XCTAssertEqual(merged.recordingFolder, "f1")
        XCTAssertEqual(merged.notePath, "meetings/x.md")
        XCTAssertEqual(merged.title, "T2")
        XCTAssertEqual(store.all().count, 1)
    }

    func testMissingOrCorruptStoreReadsAsEmpty() throws {
        let url = dir.appendingPathComponent("links.json")
        XCTAssertTrue(EventLinkStore(url: url).all().isEmpty)
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(EventLinkStore(url: url).all().isEmpty)
        XCTAssertNil(EventLinkStore.readSidecar(in: dir))
    }

    func testRecurringOccurrencesGetDistinctKeys() {
        let a = makeEvent("s", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10), recurring: true)
        let b = makeEvent("s", stamp(2026, 11, 24, 9), stamp(2026, 11, 24, 10), recurring: true)
        XCTAssertNotEqual(EventLinkStore.key(for: a), EventLinkStore.key(for: b))
    }

    func testWikilinkExtraction() {
        XCTAssertEqual(BrainLinks.wikilinks(in: "veja [[2026-11-20-10h00m-sprint]] e [[Ana|a Ana]] e [[Nota#Seção]] e [[2026-11-20-10h00m-sprint]]"),
                       ["2026-11-20-10h00m-sprint", "Ana", "Nota"])
        XCTAssertEqual(BrainLinks.wikilinks(in: nil), [])
        XCTAssertEqual(BrainLinks.wikilinks(in: "sem links [ ] [[]] [[ ]]"), [])
    }

    func testNoteFileNameFollowsTheBrainConvention() {
        XCTAssertEqual(MeetingNote.fileName(for: event(), zone: saoPaulo), "2026-11-23-15h30m-revisao-da-sprint-delfin")
        XCTAssertEqual(MeetingNote.slug("  ***  "), "reuniao")
        XCTAssertEqual(MeetingNote.slug("Reunião de Ação 2.0"), "reuniao-de-acao-2-0")
        XCTAssertLessThanOrEqual(MeetingNote.slug(String(repeating: "a", count: 200)).count, 60)
    }

    func testNoteFileNameUsesTheGivenZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(MeetingNote.fileName(for: event(), zone: tokyo), "2026-11-24-03h30m-revisao-da-sprint-delfin")
    }

    func testCreateNoteWritesFrontmatterAndNeverOverwrites() throws {
        let root = dir.appendingPathComponent("brain", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = try MeetingNote.create(for: event(), calendarTitle: "Moonxi", brainRoot: root.path, zone: saoPaulo,
                                           recordingFolder: "2026-11-23_15-30-00", now: stamp(2026, 11, 23, 15, 40))
        XCTAssertTrue(first.created)
        XCTAssertEqual(first.relativePath, "meetings/2026-11-23-15h30m-revisao-da-sprint-delfin.md")
        let body = try String(contentsOf: first.url, encoding: .utf8)
        XCTAssertTrue(body.hasPrefix("---\ndate: 2026-11-23 15:30\n"))
        XCTAssertTrue(body.contains("attendees: [Ana]"))
        XCTAssertTrue(body.contains("# Meeting — 2026-11-23 15:30 — Revisão da Sprint: Delfin!"))
        XCTAssertTrue(body.contains("- Calendar: Moonxi"))
        XCTAssertTrue(body.contains("- Link: https://meet.google.com/aaa-bbbb-ccc"))
        XCTAssertTrue(body.contains("- Recording: 2026-11-23_15-30-00"))
        XCTAssertTrue(body.contains("created: 2026-11-23 15:40"))
        try "editado".write(to: first.url, atomically: true, encoding: .utf8)
        let second = try MeetingNote.create(for: event(), calendarTitle: "Moonxi", brainRoot: root.path, zone: saoPaulo)
        XCTAssertFalse(second.created)
        XCTAssertEqual(try String(contentsOf: second.url, encoding: .utf8), "editado")
    }

    func testAppendingLinkToNotes() {
        XCTAssertEqual(MeetingNote.appendingLink(to: nil, name: "n"), "[[n]]")
        XCTAssertEqual(MeetingNote.appendingLink(to: "texto", name: "n"), "texto\n\n[[n]]")
        XCTAssertEqual(MeetingNote.appendingLink(to: "já [[n]] aqui", name: "n"), "já [[n]] aqui")
    }

    func testPreferencesDefaultsPersistenceAndVisibility() throws {
        var prefs = AgendaPreferences()
        XCTAssertEqual(prefs.mode, .week)
        XCTAssertEqual(prefs.alertLeadMinutes, 1)
        prefs.hiddenCalendars = ["c2"]
        prefs.hiddenSources = ["s9"]
        prefs.secondaryZones = ["Asia/Tokyo"]
        prefs.mode = .month
        let decoded = try JSONDecoder().decode(AgendaPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded, prefs)
        let cals = [CalCalendar(id: "c1", title: "A", sourceID: "s1", sourceTitle: "iCloud", sourceKind: .iCloud, colorHex: 1, writable: true),
                    CalCalendar(id: "c2", title: "B", sourceID: "s1", sourceTitle: "iCloud", sourceKind: .iCloud, colorHex: 2, writable: true),
                    CalCalendar(id: "c3", title: "C", sourceID: "s9", sourceTitle: "Google", sourceKind: .caldav, colorHex: 3, writable: true)]
        XCTAssertEqual(decoded.visibleCalendarIDs(cals), ["c1"])
    }

    func testPreferencesTolerateGarbageAndOldSettingsFiles() throws {
        let junk = try JSONDecoder().decode(AgendaPreferences.self, from: Data(#"{"mode":"zzz","alertLeadMinutes":9999,"hiddenCalendars":5}"#.utf8))
        XCTAssertEqual(junk.mode, .week)
        XCTAssertEqual(junk.alertLeadMinutes, 120)
        XCTAssertTrue(junk.hiddenCalendars.isEmpty)
        let old = try JSONDecoder().decode(WispSettings.self, from: Data(#"{"theme":"lime"}"#.utf8))
        XCTAssertEqual(old.agenda, AgendaPreferences())
        var settings = WispSettings.default
        settings.agenda.mode = .schedule
        let again = try JSONDecoder().decode(WispSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(again.agenda.mode, .schedule)
    }
}

final class ReminderListTests: XCTestCase {
    private let json = #"[{"id":"r1","list":"Casa","title":"Pagar luz","completed":false,"due":"2026-11-22"},{"id":"r2","list":"Casa","title":"Ligar","completed":false,"due":"2026-11-23T09:00:00-03:00"},{"id":"r3","list":"Casa","title":"Feito","completed":true,"due":"2026-11-23"},{"id":"r4","title":"Sem data","completed":false,"due":null},{"id":"r5","title":"Hoje tarde","completed":false,"due":"2026-11-23T18:00:00-03:00"},{"id":"r6","title":"Amanhã","completed":false,"due":"2026-11-24"},{"title":"sem id"}]"#

    func testParseKeepsDueKindAndSkipsGarbage() {
        let all = ReminderList.parse(Data(json.utf8), timeZone: saoPaulo)
        XCTAssertEqual(all.map(\.id), ["r1", "r2", "r3", "r4", "r5", "r6"])
        XCTAssertFalse(all[0].dueHasTime)
        XCTAssertTrue(all[1].dueHasTime)
        XCTAssertNil(all[3].due)
        XCTAssertTrue(ReminderList.parse(Data("x".utf8), timeZone: saoPaulo).isEmpty)
    }

    func testTodayAndOverdueOnlyAndSorted() {
        let all = ReminderList.parse(Data(json.utf8), timeZone: saoPaulo)
        let now = stamp(2026, 11, 23, 10)
        let list = ReminderList.dueByToday(all, now: now, calendar: makeCalendar())
        XCTAssertEqual(list.map(\.id), ["r1", "r2", "r5"])
        XCTAssertTrue(ReminderList.isOverdue(list[0], now: now, calendar: makeCalendar()))
        XCTAssertTrue(ReminderList.isOverdue(list[1], now: now.addingTimeInterval(7_200), calendar: makeCalendar()))
        XCTAssertFalse(ReminderList.isOverdue(list[2], now: now, calendar: makeCalendar()))
    }
}
