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
        _ = ledger.written(id)
    }

    // Claude with --replay-user-messages: the echo tells consumption apart.

    @Test func echoBeforeTheResultMeansMergedAndBothClose() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um"), b = submit(&ledger, "dois")
        write(&ledger, a)
        ledger.consumed()
        write(&ledger, b)
        ledger.consumed()
        #expect(ledger.result(engine: .claude).map(\.user) == ["um", "dois"])
        #expect(ledger.pending == 0)
    }

    @Test func echoAfterTheResultMeansASecondTurnOfItsOwn() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um"), b = submit(&ledger, "dois")
        write(&ledger, a)
        write(&ledger, b)
        ledger.consumed()
        #expect(ledger.result(engine: .claude).map(\.user) == ["um"])
        #expect(ledger.pending == 1)
        ledger.consumed()
        #expect(ledger.result(engine: .claude).map(\.user) == ["dois"])
        #expect(ledger.pending == 0)
    }

    @Test func resultWhileAWriteIsSuspendedClosesOnlyWhatWasEchoed() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um"), b = submit(&ledger, "dois")
        write(&ledger, a)
        ledger.consumed()
        ledger.writing(b)
        #expect(ledger.result(engine: .claude).map(\.user) == ["um"])
        #expect(ledger.pending == 1)
        #expect(ledger.written(b) == nil)
        ledger.consumed()
        #expect(ledger.result(engine: .claude).map(\.user) == ["dois"])
    }

    @Test func echoDuringASuspendedWriteIsMatchedAndClosedByTheResult() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um"), b = submit(&ledger, "dois")
        write(&ledger, a)
        ledger.consumed()
        ledger.writing(b)
        ledger.consumed()
        #expect(ledger.result(engine: .claude).map(\.user) == ["um", "dois"])
        #expect(ledger.written(b) == nil)
        #expect(ledger.pending == 0)
    }

    @Test func resultWithNoEchoAfterEchoesWereSeenClosesTheOldestWritten() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um"), b = submit(&ledger, "dois")
        write(&ledger, a)
        ledger.consumed()
        _ = ledger.result(engine: .claude)
        write(&ledger, b)
        #expect(ledger.result(engine: .claude).map(\.user) == ["dois"])
        #expect(ledger.pending == 0)
    }

    // No echo at all (an engine that does not replay).

    @Test func withoutEchoesAResultClosesEveryWrittenMessage() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um"), b = submit(&ledger, "dois")
        write(&ledger, a)
        write(&ledger, b)
        #expect(ledger.result(engine: .claude).map(\.user) == ["um", "dois"])
        #expect(ledger.pending == 0)
    }

    @Test func withoutEchoesAResultDuringAWriteCoversItAndWrittenClosesIt() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um"), b = submit(&ledger, "dois")
        write(&ledger, a)
        ledger.writing(b)
        #expect(ledger.result(engine: .claude).map(\.user) == ["um"])
        #expect(ledger.pending == 1)
        #expect(ledger.written(b)?.user == "dois")
        #expect(ledger.pending == 0)
        #expect(ledger.inFlight == 0)
    }

    // Everything else.

    @Test func aWriteAfterAResultStartsANewPendingTurn() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um")
        write(&ledger, a)
        ledger.consumed()
        #expect(ledger.result(engine: .claude).count == 1)
        let b = submit(&ledger, "dois")
        #expect(ledger.pending == 1)
        write(&ledger, b)
        ledger.consumed()
        #expect(ledger.result(engine: .claude).map(\.user) == ["dois"])
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

    @Test func nonFatalErrorClosesWhatTheEngineHadAndKeepsTheQueue() {
        var ledger = TurnLedger()
        let a = submit(&ledger, "um")
        _ = submit(&ledger, "dois")
        write(&ledger, a)
        #expect(ledger.result(engine: .claude, isError: true).map(\.user) == ["um"])
        #expect(ledger.entries.map(\.user) == ["dois"])
    }

    @Test func exitAndStopEmptyTheBooksQueueIncluded() {
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
        ledger.consumed()
        _ = submit(&ledger, "dois")
        let redo = ledger.inFlightEntries
        ledger.requeueInFlight()
        #expect(redo.map(\.user) == ["um"])
        #expect(ledger.entries.map(\.user) == ["dois", "um"])
        #expect(ledger.entries.allSatisfy { !$0.consumed })
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

    @Test func oneMirrorJoinsTheUsersAndFilesOfWhatAResultClosed() {
        var ledger = TurnLedger()
        let a = UUID(), b = UUID()
        ledger.submit(id: a, text: "um", user: "um", files: ["/x"])
        ledger.submit(id: b, text: "dois", user: "dois", files: ["/y"])
        write(&ledger, a)
        write(&ledger, b)
        ledger.consumed()
        ledger.consumed()
        let post = TurnLedger.mirror(of: ledger.result(engine: .claude))
        #expect(post?.user == "um\ndois")
        #expect(post?.files == ["/x", "/y"])
        #expect(TurnLedger.mirror(of: []) == nil)
    }
}
