import XCTest
@testable import WispCore

final class CalendarEditorTests: XCTestCase {
    private func series(_ start: Date) -> CalEvent {
        makeEvent("s1", start, start.addingTimeInterval(3_600), recurring: true, title: "Daily")
    }

    func testScopeChoicesOnlyForRecurringEvents() {
        let single = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        XCTAssertEqual(RecurrenceScope.choices(for: single), [])
        XCTAssertFalse(RecurrenceScope.needsChoice(for: single))
        XCTAssertEqual(RecurrenceScope.resolved(.all, for: single), .thisOnly)
        let rec = series(stamp(2026, 11, 23, 9))
        XCTAssertEqual(RecurrenceScope.choices(for: rec), [.thisOnly, .thisAndFuture, .all])
        XCTAssertTrue(RecurrenceScope.needsChoice(for: rec))
        XCTAssertEqual(RecurrenceScope.resolved(nil, for: rec), .thisOnly)
        XCTAssertEqual(RecurrenceScope.resolved(.all, for: rec), .all)
        XCTAssertEqual(RecurrenceScope.allCases.map(\.label), ["Só este", "Este e os próximos", "Todos"])
    }

    func testOccurrenceIdentity() {
        let rec = series(stamp(2026, 11, 23, 9))
        XCTAssertEqual(rec.ref, EventRef(id: "s1", start: stamp(2026, 11, 23, 9)))
        XCTAssertNotEqual(rec.uid, series(stamp(2026, 11, 24, 9)).uid)
        let single = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        XCTAssertEqual(single.ref, EventRef(id: "a", start: nil))
        XCTAssertEqual(single.uid, "a")
    }

    func testMovingOneOccurrenceSendsItsOwnRef() async throws {
        let backend = FakeCalendarBackend()
        let occurrence = series(stamp(2026, 11, 25, 9))
        backend.events = [occurrence]
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.update(occurrence, edit: EventEdit(start: stamp(2026, 11, 25, 10), end: stamp(2026, 11, 25, 11)), scope: .thisOnly)
        XCTAssertEqual(backend.updates.count, 1)
        XCTAssertEqual(backend.updates[0].0, occurrence.ref)
        XCTAssertEqual(backend.updates[0].2, .thisOnly)
    }

    func testThisAndFutureKeepsOccurrenceRefAndAbsoluteTimes() async throws {
        let backend = FakeCalendarBackend()
        let occurrence = series(stamp(2026, 11, 25, 9))
        backend.events = [occurrence]
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.update(occurrence, edit: EventEdit(start: stamp(2026, 11, 25, 10)), scope: .thisAndFuture)
        XCTAssertEqual(backend.updates[0].2, .thisAndFuture)
        XCTAssertEqual(backend.updates[0].1.start, stamp(2026, 11, 25, 10))
    }

    func testAllScopeShiftsTheMasterByTheSameDelta() async throws {
        let backend = FakeCalendarBackend()
        let occurrence = series(stamp(2026, 12, 2, 9))
        backend.events = [occurrence]
        backend.master = series(stamp(2026, 11, 23, 9))
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.update(occurrence, edit: EventEdit(start: stamp(2026, 12, 3, 10), end: stamp(2026, 12, 3, 11)), scope: .all)
        XCTAssertEqual(backend.updates[0].2, .all)
        XCTAssertEqual(backend.updates[0].1.start, stamp(2026, 11, 24, 10))
        XCTAssertEqual(backend.updates[0].1.end, stamp(2026, 11, 24, 11))
    }

    func testAllScopeWithoutTimeChangeNeedsNoMasterLookup() async throws {
        let backend = FakeCalendarBackend()
        let occurrence = series(stamp(2026, 12, 2, 9))
        backend.events = [occurrence]
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.update(occurrence, edit: EventEdit(title: "Novo"), scope: .all)
        XCTAssertNil(backend.updates[0].1.start)
        XCTAssertEqual(backend.updates[0].1.title, "Novo")
    }

    func testNonRecurringIgnoresRequestedScope() async throws {
        let backend = FakeCalendarBackend()
        let single = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        backend.events = [single]
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.update(single, edit: EventEdit(title: "X"), scope: .all)
        XCTAssertEqual(backend.updates[0].2, .thisOnly)
    }

    func testReadOnlyCalendarsRefuseEdits() async {
        let backend = FakeCalendarBackend()
        let locked = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10), title: "Feriado", writable: false)
        let editor = CalendarEditor(backend: backend)
        do {
            _ = try await editor.update(locked, edit: EventEdit(title: "X"), scope: nil)
            XCTFail("should refuse")
        } catch {
            XCTAssertEqual(error as? CalendarEditorError, .readOnly("Feriado"))
        }
        do {
            try await editor.delete(locked, scope: nil)
            XCTFail("should refuse")
        } catch {
            XCTAssertEqual(error as? CalendarEditorError, .readOnly("Feriado"))
        }
        XCTAssertTrue(backend.updates.isEmpty && backend.deletes.isEmpty)
        let undoable = await editor.canUndo
        XCTAssertFalse(undoable)
    }

    func testEndBeforeStartIsRefused() async {
        let backend = FakeCalendarBackend()
        let single = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        let editor = CalendarEditor(backend: backend)
        do {
            _ = try await editor.update(single, edit: EventEdit(end: stamp(2026, 11, 23, 8)), scope: nil)
            XCTFail("should refuse")
        } catch {
            XCTAssertEqual(error as? CalendarEditorError, .invalidRange)
        }
        do {
            _ = try await editor.create(EventDraft(title: "x", start: stamp(2026, 11, 23, 9), end: stamp(2026, 11, 23, 8)))
            XCTFail("should refuse")
        } catch {
            XCTAssertEqual(error as? CalendarEditorError, .invalidRange)
        }
    }

    func testUndoOfMoveRestoresPreviousTimes() async throws {
        let backend = FakeCalendarBackend()
        let single = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        backend.events = [single]
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.update(single, edit: EventEdit(start: stamp(2026, 11, 23, 11), end: stamp(2026, 11, 23, 12)), scope: nil)
        let label = try await editor.undo()
        XCTAssertEqual(label, "alterar \"E\"")
        XCTAssertEqual(backend.updates.count, 2)
        XCTAssertEqual(backend.updates[1].1.start, stamp(2026, 11, 23, 9))
        XCTAssertEqual(backend.updates[1].1.end, stamp(2026, 11, 23, 10))
    }

    func testUndoOfCreateDeletesIt() async throws {
        let backend = FakeCalendarBackend()
        let editor = CalendarEditor(backend: backend)
        let made = try await editor.create(EventDraft(title: "Novo", start: stamp(2026, 11, 23, 9), end: stamp(2026, 11, 23, 10)))
        _ = try await editor.undo()
        XCTAssertEqual(backend.deletes.first?.0, EventRef(id: made.id))
    }

    func testUndoOfDeleteRecreatesFromSnapshot() async throws {
        let backend = FakeCalendarBackend()
        var single = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10), title: "Dentista")
        single.location = "Clínica"
        backend.events = [single]
        let editor = CalendarEditor(backend: backend)
        try await editor.delete(single, scope: nil)
        _ = try await editor.undo()
        XCTAssertEqual(backend.created.first?.title, "Dentista")
        XCTAssertEqual(backend.created.first?.location, "Clínica")
    }

    func testUndoOfOccurrenceDeleteRecreatesASingleEvent() async throws {
        let backend = FakeCalendarBackend()
        var rec = series(stamp(2026, 11, 25, 9))
        rec.recurrence = CalRecurrence(frequency: .daily)
        let editor = CalendarEditor(backend: backend)
        try await editor.delete(rec, scope: .thisOnly)
        _ = try await editor.undo()
        XCTAssertNil(backend.created[0].recurrence)
        try await editor.delete(rec, scope: .all)
        _ = try await editor.undo()
        XCTAssertEqual(backend.created[1].recurrence, CalRecurrence(frequency: .daily))
    }

    func testUndoStackIsLifoAndBounded() async throws {
        let backend = FakeCalendarBackend()
        let editor = CalendarEditor(backend: backend, limit: 2)
        for n in 1...3 {
            _ = try await editor.create(EventDraft(title: "e\(n)", start: stamp(2026, 11, 23, 9), end: stamp(2026, 11, 23, 10)))
        }
        let first = try await editor.undo()
        let second = try await editor.undo()
        let third = try await editor.undo()
        XCTAssertEqual([first, second], ["criar \"e3\"", "criar \"e2\""])
        XCTAssertNil(third)
    }

    func testFailedUndoKeepsTheEntry() async throws {
        let backend = FakeCalendarBackend()
        let editor = CalendarEditor(backend: backend)
        _ = try await editor.create(EventDraft(title: "x", start: stamp(2026, 11, 23, 9), end: stamp(2026, 11, 23, 10)))
        backend.failNext = AgendaError("falhou")
        do {
            _ = try await editor.undo()
            XCTFail("should throw")
        } catch {}
        let still = await editor.canUndo
        XCTAssertTrue(still)
        _ = try await editor.undo()
        XCTAssertEqual(backend.deletes.count, 1)
    }

    func testBackendFailureLeavesNothingToUndo() async {
        let backend = FakeCalendarBackend()
        backend.failNext = AgendaError("sem rede")
        let editor = CalendarEditor(backend: backend)
        _ = try? await editor.create(EventDraft(title: "x", start: stamp(2026, 11, 23, 9), end: stamp(2026, 11, 23, 10)))
        let undoable = await editor.canUndo
        XCTAssertFalse(undoable)
    }

    func testEmptyEditIsANoOp() async throws {
        let backend = FakeCalendarBackend()
        let single = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        let editor = CalendarEditor(backend: backend)
        let same = try await editor.update(single, edit: EventEdit(), scope: nil)
        XCTAssertEqual(same, single)
        XCTAssertTrue(backend.updates.isEmpty)
    }

    func testRestoringEditCoversEveryField() {
        var e = makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        e.location = "L"
        e.notes = "N"
        e.alarmOffsets = [-600]
        e.recurrence = CalRecurrence(frequency: .weekly, interval: 2, end: .count(4))
        let edit = EventEdit.restoring(e)
        XCTAssertEqual(edit.location, "L")
        XCTAssertEqual(edit.notes, "N")
        XCTAssertEqual(edit.alarmOffsets, [-600])
        XCTAssertEqual(edit.recurrence, .set(CalRecurrence(frequency: .weekly, interval: 2, end: .count(4))))
        XCTAssertEqual(EventEdit.restoring(makeEvent("b", Date(), Date())).recurrence, .remove)
    }
}
