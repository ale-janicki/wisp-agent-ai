import XCTest
@testable import WispCore

final class RecurrenceFormTests: XCTestCase {
    private let until = stamp(2026, 12, 31, 12)
    private lazy var weekly = CalRecurrence(
        frequency: .weekly, interval: 1, end: .until(until), daysOfWeek: [RecurrenceDay(weekday: 2), RecurrenceDay(weekday: 4)])

    func testUntouchedFormKeepsTheOriginalRuleAndSendsNothing() {
        let form = RecurrenceForm(original: weekly)
        XCTAssertEqual(form.resolved, weekly)
        XCTAssertEqual(form.change(), .keep)
        XCTAssertEqual(RecurrenceForm(original: nil).change(), .keep)
    }

    func testUntilEndAndWeekdaysSurviveAnIntervalEdit() {
        var form = RecurrenceForm(original: weekly)
        form.edit { $0.interval = 2 }
        let rule = form.resolved
        XCTAssertEqual(rule?.interval, 2)
        XCTAssertEqual(rule?.end, .until(until))
        XCTAssertEqual(rule?.daysOfWeek, weekly.daysOfWeek)
        XCTAssertEqual(form.change(), .set(rule!))
    }

    func testTouchingWithoutChangingStillSendsNothing() {
        var form = RecurrenceForm(original: weekly)
        form.edit { $0.interval = 1 }
        XCTAssertEqual(form.change(), .keep)
    }

    func testChangingFrequencyDropsTheDayDetail() {
        var form = RecurrenceForm(original: weekly)
        form.edit { $0.frequency = .monthly }
        XCTAssertEqual(form.resolved, CalRecurrence(frequency: .monthly, interval: 1, end: .until(until)))
    }

    func testMonthlyRuleWithPositionsIsPreserved() {
        let rule = CalRecurrence(frequency: .monthly, end: .count(6), daysOfWeek: [RecurrenceDay(weekday: 6, weekNumber: -1)], setPositions: [-1])
        var form = RecurrenceForm(original: rule)
        form.edit { $0.endCount = 8 }
        XCTAssertEqual(form.resolved?.daysOfWeek, rule.daysOfWeek)
        XCTAssertEqual(form.resolved?.setPositions, [-1])
        XCTAssertEqual(form.resolved?.end, .count(8))
        XCTAssertTrue(rule.hasDetail)
    }

    func testEndModesAndRemoval() {
        var form = RecurrenceForm(original: weekly)
        form.edit { $0.endMode = .never }
        XCTAssertEqual(form.resolved?.end, .never)
        form.edit { $0.endMode = .count; $0.endCount = 0 }
        XCTAssertEqual(form.resolved?.end, .count(1))
        form.edit { $0.frequency = nil }
        XCTAssertEqual(form.change(), .remove)
        var fresh = RecurrenceForm(original: nil)
        fresh.edit { $0.frequency = .daily }
        XCTAssertEqual(fresh.change(), .set(CalRecurrence(frequency: .daily)))
    }
}

final class CalendarEditorReviewTests: XCTestCase {
    private let until = stamp(2026, 12, 31, 12)

    private func rule() -> CalRecurrence {
        CalRecurrence(frequency: .weekly, end: .until(until), daysOfWeek: [RecurrenceDay(weekday: 2), RecurrenceDay(weekday: 4)])
    }

    private func series(_ day: Int = 25, id: String = "s1") -> CalEvent {
        var e = makeEvent(id, stamp(2026, 11, day, 9), stamp(2026, 11, day, 10), recurring: true, title: "Daily")
        e.recurrence = rule()
        return e
    }

    func testTitleOnlyEditSendsNoRecurrenceInAnyScope() async throws {
        for scope in [RecurrenceScope.thisOnly, .thisAndFuture, .all] {
            let backend = FakeCalendarBackend()
            let event = series()
            backend.events = [event]
            let editor = CalendarEditor(backend: backend)
            _ = try await editor.update(event, edit: EventEdit(title: "Novo"), scope: scope)
            XCTAssertEqual(backend.updates[0].1.recurrence, .keep, "\(scope)")
        }
    }

    func testRecurrenceIsNeverSentWithThisOnly() async throws {
        let backend = FakeCalendarBackend()
        let event = series()
        backend.events = [event]
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.update(event, edit: EventEdit(title: "A", recurrence: .remove), scope: .thisOnly)
        XCTAssertEqual(backend.updates[0].1.recurrence, .keep)
        XCTAssertEqual(backend.updates[0].1.title, "A")
        let onlyRecurrence = try await editor.update(event, edit: EventEdit(recurrence: .remove), scope: .thisOnly)
        XCTAssertEqual(onlyRecurrence, event)
        XCTAssertEqual(backend.updates.count, 1)
    }

    func testUndoRestoresTheOriginalRuleExactlyWithTheSameScope() async throws {
        let backend = FakeCalendarBackend()
        let event = series()
        backend.events = [event]
        backend.master = series(23)
        let editor = CalendarEditor(backend: backend)
        var changed = rule()
        changed.interval = 3
        changed.end = .never
        _ = try await editor.update(event, edit: EventEdit(recurrence: .set(changed)), scope: .all)
        _ = try await editor.undo()
        XCTAssertEqual(backend.updates[1].1.recurrence, .set(rule()))
        XCTAssertEqual(backend.updates[1].2, .all)
        XCTAssertNil(backend.updates[1].1.title)
    }

    func testUndoOfThisAndFutureEditUsesThisAndFuture() async throws {
        let backend = FakeCalendarBackend()
        let event = series()
        backend.events = [event]
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.update(event, edit: EventEdit(title: "Novo"), scope: .thisAndFuture)
        _ = try await editor.undo()
        XCTAssertEqual(backend.updates[1].2, .thisAndFuture)
        XCTAssertEqual(backend.updates[1].1.title, "Daily")
        XCTAssertEqual(backend.updates[1].1.recurrence, .keep)
    }

    func testUndoOfThisOnlyEditNeverCarriesRecurrence() async throws {
        let backend = FakeCalendarBackend()
        let event = series()
        backend.events = [event]
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.update(event, edit: EventEdit(title: "Novo", recurrence: .remove), scope: .thisOnly)
        _ = try await editor.undo()
        XCTAssertEqual(backend.updates[1].2, .thisOnly)
        XCTAssertEqual(backend.updates[1].1.recurrence, .keep)
    }

    func testUndoOfThisAndFutureDeleteRecreatesTheFutureSeriesWithItsRule() async throws {
        let backend = FakeCalendarBackend()
        let editor = CalendarEditor(backend: backend)
        try await editor.delete(series(), scope: .thisAndFuture)
        XCTAssertEqual(backend.deletes[0].1, .thisAndFuture)
        let result = try await editor.undo()
        XCTAssertEqual(backend.created[0].recurrence, rule())
        XCTAssertEqual(backend.created[0].start, stamp(2026, 11, 25, 9))
        XCTAssertNotNil(result?.caveat)
        XCTAssertTrue(result?.caveat?.contains("série") == true)
    }

    func testUndoOfSingleOccurrenceDeleteSaysItComesBackStandalone() async throws {
        let backend = FakeCalendarBackend()
        let editor = CalendarEditor(backend: backend)
        try await editor.delete(series(), scope: .thisOnly)
        let result = try await editor.undo()
        XCTAssertNil(backend.created[0].recurrence)
        XCTAssertTrue(result?.caveat?.contains("avulso") == true)
        XCTAssertTrue(result?.message.hasPrefix("Desfeito: apagar") == true)
    }

    func testUndoOfDeleteWithGuestsAdmitsPartialRestore() async throws {
        let backend = FakeCalendarBackend()
        var event = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        event.attendees = [CalAttendee(name: "Ana"), CalAttendee(name: "Eu", isMe: true)]
        let editor = CalendarEditor(backend: backend)
        try await editor.delete(event, scope: nil)
        let result = try await editor.undo()
        XCTAssertTrue(result?.caveat?.contains("convidados") == true)
        XCTAssertTrue(result?.caveat?.contains("cancelamentos") == true)
        let plain = makeEvent("b", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        try await editor.delete(plain, scope: nil)
        let plainResult = try await editor.undo()
        XCTAssertNotNil(plainResult)
        XCTAssertNil(plainResult?.caveat)
    }

    func testDeletePromptWarnsAboutCancellationsWhenThereAreGuests() {
        var event = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10), title: "Sprint Review")
        let plain = DeletePrompt.make(for: event)
        XCTAssertFalse(plain.notifiesGuests)
        XCTAssertEqual(plain.title, "Apagar \"Sprint Review\"?")
        event.attendees = [CalAttendee(name: "Ana"), CalAttendee(name: "Beto"), CalAttendee(name: "Eu", isMe: true)]
        let guests = DeletePrompt.make(for: event)
        XCTAssertTrue(guests.notifiesGuests)
        XCTAssertTrue(guests.detail.contains("2 convidados"))
        XCTAssertTrue(guests.detail.contains("cancelamento"))
        XCTAssertTrue(guests.detail.contains("não pode ser desfeito"))
        event.attendees = [CalAttendee(name: "Ana")]
        XCTAssertTrue(DeletePrompt.make(for: event).detail.contains("1 convidado "))
    }

    func testUndoDropsAnEntryWhoseEventIsGone() async throws {
        let backend = FakeCalendarBackend()
        let event = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        backend.events = [event]
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.update(event, edit: EventEdit(title: "X"), scope: nil)
        backend.missing = ["a"]
        do {
            _ = try await editor.undo()
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? CalendarEditorError, .undoTargetGone)
        }
        let stuck = await editor.canUndo
        XCTAssertFalse(stuck)
    }

    func testUndoKeepsAnEntryOnATransientFailure() async throws {
        let backend = FakeCalendarBackend()
        let event = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        backend.events = [event]
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.update(event, edit: EventEdit(title: "X"), scope: nil)
        backend.failNext = AgendaError("rede")
        _ = try? await editor.undo()
        let kept = await editor.canUndo
        XCTAssertTrue(kept)
    }

    func testRecreatedEventUpdatesOlderEntriesToTheNewId() async throws {
        let backend = FakeCalendarBackend()
        let event = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        backend.events = [event]
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.update(event, edit: EventEdit(title: "X"), scope: nil)
        try await editor.delete(event, scope: nil)
        backend.nextID = "a2"
        backend.events = [makeEvent("a2", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))]
        _ = try await editor.undo()
        _ = try await editor.undo()
        XCTAssertEqual(backend.updates.last?.0.id, "a2")
    }

    func testEditRefusedWhenTheEventChangedOutsideTheApp() async throws {
        let backend = FakeCalendarBackend()
        var event = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        event.modified = stamp(2026, 11, 23, 8)
        backend.events = [event]
        backend.storedModified["a"] = stamp(2026, 11, 23, 8, 30)
        let editor = CalendarEditor(backend: backend)
        do {
            _ = try await editor.update(event, edit: EventEdit(title: "X"), scope: nil)
            XCTFail("should refuse")
        } catch {
            XCTAssertEqual(error as? CalendarBackendError, .modifiedExternally("a"))
        }
        do {
            try await editor.delete(event, scope: nil)
            XCTFail("should refuse")
        } catch {
            XCTAssertEqual(error as? CalendarBackendError, .modifiedExternally("a"))
        }
        XCTAssertTrue(backend.updates.isEmpty && backend.deletes.isEmpty)
        let undoable = await editor.canUndo
        XCTAssertFalse(undoable)
        XCTAssertTrue(CalendarBackendError.modifiedExternally("Reunião").localizedDescription.contains("mudou fora do Wisp"))
    }

    func testEditPassesTheModifiedDateAndSucceedsWhenUnchanged() async throws {
        let backend = FakeCalendarBackend()
        var event = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        event.modified = stamp(2026, 11, 23, 8)
        backend.events = [event]
        backend.storedModified["a"] = stamp(2026, 11, 23, 8)
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.update(event, edit: EventEdit(title: "X"), scope: nil)
        XCTAssertEqual(backend.expectations, [stamp(2026, 11, 23, 8)])
    }
}

final class DaylightSavingTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private lazy var calendar = makeCalendar(newYork)

    private func at(_ m: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date { stamp(2026, m, d, h, mi, zone: newYork) }

    func testAllDayEndIsTheLastSecondOfTheLocalDayOnTransitionDays() {
        for (m, d) in [(3, 8), (11, 1), (3, 9)] {
            let day = at(m, d, 0)
            let end = CalendarDates.allDayEnd(lastDay: day, calendar: calendar)
            let parts = calendar.dateComponents([.day, .hour, .minute, .second], from: end)
            XCTAssertEqual([parts.day, parts.hour, parts.minute, parts.second], [d, 23, 59, 59], "\(m)/\(d)")
            XCTAssertEqual(end.addingTimeInterval(1), calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)))
        }
    }

    func testAllDayEventLastDayRoundTripsOnTransitionDays() {
        let day = at(3, 8, 0)
        let event = makeEvent("a", day, CalendarDates.allDayEnd(lastDay: day, calendar: calendar), allDay: true)
        XCTAssertEqual(CalendarDates.lastDay(of: event, calendar: calendar), day)
    }

    func testMinuteOfDayIsWallClockNotElapsedTime() {
        XCTAssertEqual(GridMath.minuteOfDay(at(3, 8, 15), calendar: calendar), 900)
        XCTAssertEqual(GridMath.minuteOfDay(at(11, 1, 15), calendar: calendar), 900)
    }

    func testNonexistentWallClockTimeLandsAfterTheGap() {
        let date = GridMath.date(onDayOf: at(3, 8, 12), minute: 150, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: date), 3)
        XCTAssertEqual(GridMath.date(onDayOf: at(3, 8, 12), minute: 1_440, calendar: calendar), at(3, 9, 0))
    }

    func testMoveKeepsTheWallClockOnADstDay() {
        let span = TimeSpan(start: at(3, 8, 15), end: at(3, 8, 16))
        let same = GridMath.move(span, deltaMinutes: 0, deltaDays: 0, calendar: calendar)
        XCTAssertEqual(same.start, span.start)
        let nextDay = GridMath.move(span, deltaMinutes: 0, deltaDays: 1, calendar: calendar)
        XCTAssertEqual(nextDay.start, at(3, 9, 15))
        let back = GridMath.move(TimeSpan(start: at(11, 1, 15), end: at(11, 1, 16)), deltaMinutes: 30, deltaDays: 0, calendar: calendar)
        XCTAssertEqual(back.start, at(11, 1, 15, 30))
    }

    func testResizeOnADstDay() {
        let span = TimeSpan(start: at(3, 8, 15), end: at(3, 8, 16))
        XCTAssertEqual(GridMath.resizeEnd(span, deltaMinutes: 30, calendar: calendar).end, at(3, 8, 16, 30))
        XCTAssertEqual(GridMath.resizeStart(span, deltaMinutes: -30, calendar: calendar).start, at(3, 8, 14, 30))
    }

    func testSpanOnDayBuildsLocalWallClockTimes() {
        let span = GridMath.span(onDay: at(3, 8, 20), startMinute: 540, endMinute: 600, calendar: calendar)
        XCTAssertEqual(span?.start, at(3, 8, 9))
        XCTAssertEqual(span?.end, at(3, 8, 10))
    }

    func testLayoutSegmentUsesWallClockMinutes() {
        let event = makeEvent("a", at(3, 8, 15), at(3, 8, 16))
        let segment = EventLayout.segment(of: event, on: at(3, 8, 0), calendar: calendar)
        XCTAssertEqual([segment?.startMinute, segment?.endMinute], [900, 960])
        let late = makeEvent("b", at(11, 1, 23), at(11, 2, 0))
        XCTAssertEqual(EventLayout.segment(of: late, on: at(11, 1, 0), calendar: calendar)?.endMinute, 1_440)
    }

    func testAvailabilityOpensAtLocalNineOnADstDay() {
        let slots = Availability.freeSlots(from: at(3, 9, 0), days: 1, busy: [], hours: .standard, calendar: calendar, now: at(3, 1, 0))
        XCTAssertEqual(slots.first?.start, at(3, 9, 9))
        XCTAssertEqual(slots.first?.end, at(3, 9, 18))
    }

    func testQuickCreateOnADstDay() {
        let now = at(3, 1, 10)
        let parsed = QuickEventParser.parse("reunião 8/3 15h", now: now, calendar: calendar)
        XCTAssertEqual(parsed?.start, at(3, 8, 15))
        XCTAssertEqual(parsed?.end, at(3, 8, 16))
        let allDay = QuickEventParser.parse("feriado 8/3", now: now, calendar: calendar)
        XCTAssertEqual(allDay?.end, CalendarDates.allDayEnd(lastDay: at(3, 8, 0), calendar: calendar))
    }
}

final class QuickParserRobustnessTests: XCTestCase {
    private let calendar = makeCalendar()
    private lazy var now = stamp(2026, 11, 21, 10)

    private func parse(_ text: String) -> QuickEvent {
        QuickEventParser.parse(text, now: now, calendar: calendar, calendarNames: ["Trabalho"])!
    }

    func testHugeNumbersDoNotCrashAndStayPlainTitles() {
        for text in ["x em 99999999999999999999 dias", "x por 99999999999999999999 horas", "9223372036854775807h30m",
                     "x in 99999999999999999999 days", "x for 9223372036854775807 minutes", "x em 99999 semanas", "x por 99999h",
                     "x 99999999999999999999/12", "x dia 99999999999999999999", "x 1e20 horas"] {
            let r = parse(text)
            XCTAssertEqual(r.title, text, text)
            XCTAssertFalse(r.hasDate, text)
            XCTAssertFalse(r.hasTime, text)
        }
    }

    func testDurationIsClampedToOneMinuteThroughSevenDays() {
        XCTAssertEqual(parse("call amanhã 10h por 200h").title, "call por 200h")
        XCTAssertEqual(parse("call amanhã 10h por 200h").end, stamp(2026, 11, 22, 11))
        XCTAssertEqual(parse("call amanhã 10h por 0 min").title, "call por 0 min")
        let week = parse("viagem amanhã 10h por 168h")
        XCTAssertEqual(week.end, stamp(2026, 11, 29, 10))
        XCTAssertEqual(week.title, "viagem")
        XCTAssertEqual(parse("call amanhã 10h por 1 min").end, stamp(2026, 11, 22, 10, 1))
        XCTAssertEqual(parse("call amanhã 10h por 10081 min").title, "call por 10081 min")
    }

    func testFourDigitQuantitiesStillWork() {
        XCTAssertEqual(parse("entrega em 365 dias").start, stamp(2026, 11, 21).addingTimeInterval(365 * 86_400))
        XCTAssertTrue(parse("entrega em 9999 dias").allDay)
    }

    func testSpecialCaseFoldingKeepsTitlesAndTimesAligned() {
        let a = parse("İstanbul trip sexta 10h")
        XCTAssertEqual(a.title, "İstanbul trip")
        XCTAssertEqual(a.start, stamp(2026, 11, 27, 10))
        let b = parse("ﬁnal review amanhã 15h")
        XCTAssertEqual(b.title, "ﬁnal review")
        XCTAssertEqual(b.start, stamp(2026, 11, 22, 15))
        let c = parse("Straße meeting sexta 10-11 no calendário trabalho")
        XCTAssertEqual(c.title, "Straße meeting")
        XCTAssertEqual(c.calendarName, "Trabalho")
        XCTAssertEqual(c.end, stamp(2026, 11, 27, 11))
        let d = parse("İİİ ﬁﬁ ß amanhã às 9 @ Café ﬁnal")
        XCTAssertEqual(d.title, "İİİ ﬁﬁ ß")
        XCTAssertEqual(d.location, "Café ﬁnal")
        XCTAssertEqual(d.start, stamp(2026, 11, 22, 9))
    }

    func testDecomposedAccentsAreAligned() {
        let r = parse("Cafe\u{301} da manha\u{303} amanha\u{303} 9h")
        XCTAssertEqual(r.start, stamp(2026, 11, 22, 9))
        XCTAssertEqual(r.title.precomposedStringWithCanonicalMapping, "Café da manhã")
    }
}

final class HiddenTitleTests: XCTestCase {
    func testPreferenceDefaultsToOffAndPersists() throws {
        var prefs = AgendaPreferences()
        XCTAssertFalse(prefs.hideTitlesInAlerts)
        prefs.hideTitlesInAlerts = true
        XCTAssertTrue(try JSONDecoder().decode(AgendaPreferences.self, from: JSONEncoder().encode(prefs)).hideTitlesInAlerts)
        XCTAssertFalse(try JSONDecoder().decode(AgendaPreferences.self, from: Data("{}".utf8)).hideTitlesInAlerts)
    }

    func testAlertsAndMenuBarShowAGenericTitleWhenHidden() {
        var event = makeEvent("a", stamp(2026, 11, 23, 10), stamp(2026, 11, 23, 11), title: "Revisão salarial")
        event.url = URL(string: "https://meet.google.com/aaa-bbbb-ccc")
        let now = stamp(2026, 11, 23, 9)
        XCTAssertEqual(MeetingLinks.alerts(for: [event], now: now, leadMinutes: 1)[0].title, "Revisão salarial")
        XCTAssertEqual(MeetingLinks.alerts(for: [event], now: now, leadMinutes: 1, hideTitles: true)[0].title, "Reunião")
        let start = event.start
        XCTAssertEqual(MeetingLinks.menuBarTitle(title: "Revisão salarial", start: start, end: event.end, now: start.addingTimeInterval(-300), hideTitle: true),
                       "Reunião · em 5 min")
        XCTAssertEqual(MeetingLinks.displayTitle("X", hidden: false), "X")
    }
}

final class SeriesSnapshotTests: XCTestCase {
    private func counted(_ day: Int) -> CalEvent {
        var e = makeEvent("s1", stamp(2026, 11, day, 9), stamp(2026, 11, day, 10), recurring: true, title: "Aula")
        e.recurrence = CalRecurrence(frequency: .daily, end: .count(5))
        return e
    }

    func testDeletingAllFromTheThirdOccurrenceRecreatesTheWholeSeries() async throws {
        let backend = FakeCalendarBackend()
        backend.master = counted(23)
        let editor = CalendarEditor(backend: backend)
        try await editor.delete(counted(25), scope: .all)
        _ = try await editor.undo()
        XCTAssertEqual(backend.created[0].start, stamp(2026, 11, 23, 9))
        XCTAssertEqual(backend.created[0].recurrence?.end, .count(5))
    }

    func testUndoOfDeleteAllSaysSeriesExceptionsAreNotRestored() async throws {
        let backend = FakeCalendarBackend()
        backend.master = counted(23)
        let editor = CalendarEditor(backend: backend)
        try await editor.delete(counted(25), scope: .all)
        let result = try await editor.undo()
        XCTAssertTrue(result?.caveat?.contains("exceções da série") == true)
        XCTAssertFalse(result?.caveat?.contains("não consegui ler a série") == true)
    }

    func testDeleteAllWithUnreadableMasterSaysTheSeriesStartsFromThisOccurrence() async throws {
        let backend = FakeCalendarBackend()
        let editor = CalendarEditor(backend: backend)
        try await editor.delete(counted(25), scope: .all)
        _ = try await editor.undo()
        XCTAssertEqual(backend.created[0].start, stamp(2026, 11, 25, 9))
    }

    func testUnreadableMasterCaveatIsReported() async throws {
        let backend = FakeCalendarBackend()
        let editor = CalendarEditor(backend: backend)
        try await editor.delete(counted(25), scope: .all)
        let result = try await editor.undo()
        XCTAssertTrue(result?.caveat?.contains("recriada a partir desta ocorrência") == true)
    }

    func testUndoOfDeletingASeriesWithSeveralRulesSaysOnlyTheFirstIsRecreated() async throws {
        let backend = FakeCalendarBackend()
        var event = counted(25)
        event.recurrenceRuleCount = 2
        backend.master = event
        let editor = CalendarEditor(backend: backend)
        try await editor.delete(event, scope: .all)
        let all = try await editor.undo()
        XCTAssertTrue(all?.caveat?.contains("mais de uma regra") == true)
        try await editor.delete(event, scope: .thisAndFuture)
        let future = try await editor.undo()
        XCTAssertTrue(future?.caveat?.contains("mais de uma regra") == true)
        try await editor.delete(event, scope: .thisOnly)
        let single = try await editor.undo()
        XCTAssertFalse(single?.caveat?.contains("mais de uma regra") == true)
        try await editor.delete(counted(25), scope: .thisAndFuture)
        let one = try await editor.undo()
        XCTAssertFalse(one?.caveat?.contains("mais de uma regra") == true)
    }

    func testDeletingThisAndFutureWithACountAdmitsTheCountRestarts() async throws {
        let backend = FakeCalendarBackend()
        let editor = CalendarEditor(backend: backend)
        try await editor.delete(counted(25), scope: .thisAndFuture)
        let result = try await editor.undo()
        XCTAssertEqual(backend.created[0].start, stamp(2026, 11, 25, 9))
        XCTAssertTrue(result?.caveat?.contains("recomeça") == true)
    }

    func testUndoOfThisAndFutureEditSaysTheSplitSeriesIsNotJoined() async throws {
        let backend = FakeCalendarBackend()
        let event = counted(25)
        backend.events = [event]
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.update(event, edit: EventEdit(title: "Novo"), scope: .thisAndFuture)
        let result = try await editor.undo()
        XCTAssertTrue(result?.caveat?.contains("não é juntada") == true)
        let single = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        backend.events.append(single)
        _ = try await editor.update(single, edit: EventEdit(title: "X"), scope: nil)
        let plain = try await editor.undo()
        XCTAssertNotNil(plain)
        XCTAssertNil(plain?.caveat)
    }

    func testEventWithSeveralRulesNeverHasItsRulesTouched() async throws {
        let backend = FakeCalendarBackend()
        var event = counted(25)
        event.recurrenceRuleCount = 2
        XCTAssertTrue(event.hasMultipleRules)
        XCTAssertFalse(counted(25).hasMultipleRules)
        backend.events = [event]
        backend.master = event
        let editor = CalendarEditor(backend: backend)
        for scope in [RecurrenceScope.thisAndFuture, .all] {
            _ = try await editor.update(event, edit: EventEdit(title: "Novo", recurrence: .remove), scope: scope)
            XCTAssertEqual(backend.updates.last?.1.recurrence, .keep)
            XCTAssertEqual(backend.updates.last?.1.title, "Novo")
        }
        let only = try await editor.update(event, edit: EventEdit(recurrence: .set(CalRecurrence(frequency: .weekly))), scope: .all)
        XCTAssertEqual(only, event)
        XCTAssertEqual(backend.updates.count, 2)
    }
}
