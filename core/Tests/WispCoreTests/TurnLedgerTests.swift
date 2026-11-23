import Foundation
import Testing
@testable import WispCore

@Suite struct TurnLedgerTests {
    private func submit(_ ledger: inout TurnLedger, _ text: String) -> UUID {
        let id = UUID()
        ledger.submit(id: id, text: text, user: text, files: [])
        return id
    }

    private func write(_ ledger: inout TurnLedger, _ id: UUID) {
        ledger.writing(id)
        ledger.written(id)
    }

    @Test func mergedTurnClosesEveryWrittenMessageInOrder() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um"), b = submit(&ledger, "dois")
        write(&ledger, a)
        write(&ledger, b)
        let closed = ledger.result(engine: .claude)
        #expect(closed.map(\.user) == ["um", "dois"])
        #expect(ledger.pending == 0)
        #expect(ledger.inFlight == 0)
    }

    @Test func resultDuringASuspendedWriteDoesNotCloseThatMessage() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um"), b = submit(&ledger, "dois")
        write(&ledger, a)
        ledger.writing(b)
        #expect(ledger.result(engine: .claude).map(\.user) == ["um"])
        #expect(ledger.pending == 1)
        #expect(ledger.inFlight == 1)
        ledger.written(b)
        #expect(ledger.result(engine: .claude).map(\.user) == ["dois"])
        #expect(ledger.pending == 0)
        #expect(ledger.inFlight == 0)
    }

    @Test func aWriteAfterAResultStartsANewPendingTurn() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um")
        write(&ledger, a)
        #expect(ledger.result(engine: .claude).count == 1)
        let b = submit(&ledger, "dois")
        #expect(ledger.pending == 1)
        write(&ledger, b)
        #expect(ledger.result(engine: .claude).map(\.user) == ["dois"])
    }

    @Test func aStuckLedgerNeverOutlivesWhatIsInIt() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um")
        write(&ledger, a)
        _ = ledger.result(engine: .claude)
        #expect(ledger.result(engine: .claude).isEmpty)
        #expect(ledger.pending == 0)
    }

    @Test func codexAndLocalCloseOneMessagePerResult() {
        for engine in [EngineKind.codex, .local] {
            var ledger = TurnLedger()
            let a = submit(&ledger, "um"), b = submit(&ledger, "dois")
            write(&ledger, a)
            write(&ledger, b)
            #expect(ledger.result(engine: engine).map(\.user) == ["um"])
            #expect(ledger.pending == 1)
            #expect(ledger.result(engine: engine).map(\.user) == ["dois"])
            #expect(ledger.pending == 0)
        }
    }

    @Test func resetEmptiesTheBooks() {
        var ledger = TurnLedger()
        write(&ledger, submit(&ledger, "um"))
        _ = submit(&ledger, "dois")
        ledger.reset()
        #expect(ledger.pending == 0)
        #expect(ledger.inFlight == 0)
    }

    @Test func rebuildPutsWhatTheEngineHadBackAfterTheQueue() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um")
        write(&ledger, a)
        _ = submit(&ledger, "dois")
        let redo = ledger.inFlightEntries
        ledger.requeueInFlight()
        #expect(redo.map(\.user) == ["um"])
        #expect(ledger.entries.map(\.user) == ["dois", "um"])
        #expect(ledger.inFlight == 0)
        #expect(ledger.pending == 2)
        #expect(ledger.result(engine: .claude).isEmpty)
    }

    @Test func aFailedWriteLeavesTheBooks() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um"), b = submit(&ledger, "dois")
        write(&ledger, a)
        ledger.writing(b)
        ledger.writeFailed(b)
        #expect(ledger.pending == 1)
        #expect(ledger.inFlight == 1)
    }

    @Test func aRestartedProcessLosesWhatItHadButNotTheQueue() {
        var ledger = TurnLedger()
        write(&ledger, submit(&ledger, "um"))
        _ = submit(&ledger, "dois")
        ledger.processRestarted()
        #expect(ledger.entries.map(\.user) == ["dois"])
    }
}
