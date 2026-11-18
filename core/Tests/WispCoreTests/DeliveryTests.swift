import Foundation
import Testing
@testable import WispCore

@Suite struct DeliveryPolicyTests {
    @Test func notConfiguredRunsLocal() {
        #expect(DeliveryPolicy.route(telegramConfigured: false, canSend: false, downReason: "fora") == .local)
        #expect(DeliveryPolicy.route(telegramConfigured: false, canSend: true, downReason: nil) == .local)
    }

    @Test func configuredAndUpSendsTelegram() {
        #expect(DeliveryPolicy.route(telegramConfigured: true, canSend: true, downReason: nil) == .telegram)
    }

    @Test func configuredAndDownHolds() {
        let route = DeliveryPolicy.route(telegramConfigured: true, canSend: false, downReason: "nenhuma máquina está lendo o Telegram")
        #expect(route == .hold(reason: "nenhuma máquina está lendo o Telegram"))
    }

    @Test func configuredAndCheckingHolds() {
        #expect(DeliveryPolicy.route(telegramConfigured: true, canSend: false, downReason: nil) == .hold(reason: "o Telegram está fora do ar"))
    }
}

@Suite(.serialized) final class OutboxTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-outbox-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func message(_ text: String, at seconds: TimeInterval, conversation: UUID = UUID(), thread: Int? = nil, files: [String]? = nil) -> HeldMessage {
        HeldMessage(conversationId: conversation, thread: thread, text: text, heldAt: Date(timeIntervalSince1970: seconds), files: files)
    }

    @Test func survivesReload() throws {
        let held = message("oi", at: 1_700_000_000.25, thread: 42, files: ["/tmp/a.png"])
        try Outbox(directory: dir).append(held)
        let reloaded = Outbox(directory: dir).all()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.id == held.id)
        #expect(reloaded.first?.thread == 42)
        #expect(reloaded.first?.text == "oi")
        #expect(reloaded.first?.files == ["/tmp/a.png"])
        #expect(abs((reloaded.first?.heldAt.timeIntervalSince1970 ?? 0) - 1_700_000_000.25) < 0.001)
    }

    @Test func ordersOldestFirst() throws {
        let outbox = Outbox(directory: dir)
        try outbox.append(message("dois", at: 2_000))
        try outbox.append(message("um", at: 1_000))
        try outbox.append(message("três", at: 3_000))
        #expect(outbox.all().map(\.text) == ["um", "dois", "três"])
        #expect(Outbox(directory: dir).all().map(\.text) == ["um", "dois", "três"])
    }

    @Test func removeById() throws {
        let outbox = Outbox(directory: dir)
        let keep = message("fica", at: 1_000)
        let gone = message("sai", at: 2_000)
        try outbox.append(keep)
        try outbox.append(gone)
        try outbox.remove(id: gone.id)
        try outbox.remove(id: UUID())
        #expect(outbox.all().map(\.id) == [keep.id])
        #expect(Outbox(directory: dir).all().map(\.id) == [keep.id])
    }

    @Test func assignThreadGivesTheConversationItsTopic() throws {
        let outbox = Outbox(directory: dir)
        let conversation = UUID()
        try outbox.append(message("um", at: 1_000, conversation: conversation))
        try outbox.append(message("dois", at: 2_000, conversation: conversation))
        try outbox.append(message("outra", at: 3_000))
        try outbox.assignThread(7, conversationId: conversation)
        #expect(Outbox(directory: dir).all().map(\.thread) == [7, 7, nil])
    }

    @Test func corruptFileStartsEmptyKeepsBad() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json {".utf8).write(to: dir.appendingPathComponent("outbox.json"))
        let outbox = Outbox(directory: dir)
        #expect(outbox.all().isEmpty)
        let bad = dir.appendingPathComponent("outbox.json.bad")
        #expect(try Data(contentsOf: bad) == Data("not json {".utf8))
        #expect(outbox.lastRecoveryNote?.contains("outbox.json.bad") == true)
        #expect(Outbox(directory: dir).lastRecoveryNote == nil)
    }
}

@Suite struct OutboxFailureTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-outbox-\(UUID().uuidString)")

    @Test func replaceKeepsFailureAndAttemptsAcrossReload() throws {
        let outbox = Outbox(directory: dir)
        let held = HeldMessage(conversationId: UUID(), thread: 3, text: "oi", heldAt: Date(timeIntervalSince1970: 1_000))
        try outbox.append(held)
        try outbox.replace(OutboxPlan.failed(held, sentence: "o bot recusou", now: Date(timeIntervalSince1970: 2_000), retry: true))
        let reloaded = try #require(Outbox(directory: dir).all().first)
        #expect(reloaded.failure == "o bot recusou")
        #expect(reloaded.attempts == 1)
        #expect(reloaded.retryAt == Date(timeIntervalSince1970: 2_010))
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func failKeepsTheThreadAssignedMeanwhile() throws {
        let outbox = Outbox(directory: dir)
        let conversation = UUID()
        let stale = HeldMessage(conversationId: conversation, thread: nil, text: "oi", heldAt: Date(timeIntervalSince1970: 1_000))
        try outbox.append(stale)
        try outbox.assignThread(101, conversationId: conversation)
        let failed = try outbox.fail(id: stale.id, sentence: "o bot recusou", now: Date(timeIntervalSince1970: 2_000), retry: true)
        #expect(failed?.thread == 101)
        #expect(failed?.attempts == 1)
        #expect(Outbox(directory: dir).all().first?.thread == 101)
        #expect(try outbox.fail(id: UUID(), sentence: "x", now: Date(), retry: true) == nil)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func fileWithoutTheNewFieldsStillLoads() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID()
        let old = #"[{"conversationId":"\#(UUID().uuidString)","heldAt":1000,"id":"\#(id.uuidString)","text":"oi"}]"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("outbox.json"))
        let loaded = Outbox(directory: dir).all()
        #expect(loaded.map(\.id) == [id])
        #expect(loaded.first?.attempts == 0)
        #expect(loaded.first?.failure == nil)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func secondCorruptionKeepsTheEarlierBadCopy() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("outbox.json")
        try Data("um {".utf8).write(to: file)
        _ = Outbox(directory: dir)
        try Data("dois {".utf8).write(to: file)
        _ = Outbox(directory: dir)
        #expect(try Data(contentsOf: dir.appendingPathComponent("outbox.json.bad")) == Data("dois {".utf8))
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("outbox.json.bad-") }
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(kept[0])) == Data("um {".utf8))
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func unreadableFileStaysAndRefusesWrites() throws {
        let file = dir.appendingPathComponent("outbox.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let outbox = Outbox(directory: dir)
        #expect(outbox.all().isEmpty)
        #expect(outbox.lastRecoveryNote?.contains("não consegui ler") == true)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("outbox.json.bad").path))
        #expect(throws: OutboxError.self) {
            try outbox.append(HeldMessage(conversationId: UUID(), thread: nil, text: "oi"))
        }
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) && isDir.boolValue)
        try? FileManager.default.removeItem(at: dir)
    }
}

@Suite struct OutboxPlanTests {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let a = UUID()
    private let b = UUID()

    private func held(_ text: String, _ conversation: UUID, at seconds: TimeInterval, thread: Int? = nil) -> HeldMessage {
        HeldMessage(conversationId: conversation, thread: thread, text: text, heldAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func nextIsTheOldestHead() {
        let all = [held("a1", a, at: 1), held("b1", b, at: 2), held("a2", a, at: 3)]
        #expect(OutboxPlan.next(all, now: now)?.text == "a1")
    }

    @Test func failedHeadBlocksItsConversationOnly() {
        let failed = OutboxPlan.failed(held("a1", a, at: 1), sentence: "x", now: now, retry: false)
        let all = [failed, held("a2", a, at: 2), held("b1", b, at: 3)]
        #expect(OutboxPlan.next(all, now: now)?.text == "b1")
        #expect(OutboxPlan.next([failed, held("a2", a, at: 2)], now: now) == nil)
        #expect(!OutboxPlan.hasWork([failed, held("a2", a, at: 2)]))
    }

    @Test func backoffIsTenThirtySixtyThenFailed() {
        var m = held("a1", a, at: 1)
        var waits: [TimeInterval?] = []
        for _ in 0..<4 {
            m = OutboxPlan.failed(m, sentence: "fora", now: now, retry: true)
            waits.append(m.retryAt?.timeIntervalSince(now))
        }
        #expect(waits == [10, 30, 60, nil])
        #expect(m.attempts == 4)
        #expect(m.isFailed)
        #expect(m.failure == "fora")
    }

    @Test func waitingHeadIsSkippedUntilItsTime() {
        let waiting = OutboxPlan.failed(held("a1", a, at: 1), sentence: "x", now: now, retry: true)
        let all = [waiting, held("a2", a, at: 2), held("b1", b, at: 3)]
        #expect(OutboxPlan.next(all, now: now)?.text == "b1")
        #expect(OutboxPlan.next(all, now: now.addingTimeInterval(10))?.text == "a1")
        #expect(OutboxPlan.hasWork([waiting]))
    }

    @Test func noRetryFailsAtOnce() {
        let m = OutboxPlan.failed(held("a1", a, at: 1), sentence: "pode já ter chegado", now: now, retry: false)
        #expect(m.isFailed)
        #expect(m.retryAt == nil)
    }

    @Test func retriedClearsEverything() {
        let failed = OutboxPlan.failed(held("a1", a, at: 1), sentence: "x", now: now, retry: false)
        let again = OutboxPlan.retried(failed)
        #expect(again.failure == nil && again.attempts == 0 && again.retryAt == nil)
        #expect(OutboxPlan.next([again], now: now)?.id == failed.id)
    }

    @Test func pauseWakesForTheNearestRetry() {
        let waiting = OutboxPlan.failed(held("a1", a, at: 1), sentence: "x", now: now, retry: true)
        #expect(OutboxPlan.pause([held("b1", b, at: 1)], now: now) == 10)
        #expect(OutboxPlan.pause([waiting], now: now.addingTimeInterval(7)) == 3)
        #expect(OutboxPlan.pause([waiting], now: now.addingTimeInterval(20)) == 0)
    }

    @Test func threadComesFromTheMessageThenTheRecordThenTheLink() {
        #expect(OutboxPlan.thread(held("a", a, at: 1, thread: 5), record: 6, linked: 7) == 5)
        #expect(OutboxPlan.thread(held("a", a, at: 1), record: 6, linked: 7) == 6)
        #expect(OutboxPlan.thread(held("a", a, at: 1), record: nil, linked: 7) == 7)
        #expect(OutboxPlan.thread(held("a", a, at: 1), record: nil, linked: nil) == nil)
    }

    @Test func missingFileNamesTheFirstGone() {
        var m = held("a", a, at: 1)
        m.files = ["/x/ok.png", "/x/gone.pdf"]
        #expect(OutboxPlan.missingFile(m) { $0 == "/x/ok.png" } == "gone.pdf")
        #expect(OutboxPlan.missingFile(m) { _ in true } == nil)
    }

    @Test func markShowsSendingFailedAndUnconfigured() {
        let m = held("a", a, at: 1)
        let failed = OutboxPlan.failed(m, sentence: "x", now: now, retry: false)
        #expect(OutboxPlan.mark(m, telegramConfigured: true, inFlight: nil) == .queued)
        #expect(OutboxPlan.mark(m, telegramConfigured: true, inFlight: m.id) == .sending)
        #expect(OutboxPlan.mark(failed, telegramConfigured: true, inFlight: nil) == .failed("x", canRetry: true))
        #expect(OutboxPlan.mark(m, telegramConfigured: false, inFlight: nil) == .failed("Telegram não está configurado", canRetry: false))
    }

    @Test func phaseReasonExplainsWhyTheConversationWaits() {
        let first = held("a1", a, at: 1)
        #expect(OutboxPlan.phaseReason(conversation: a, [first], now: now, botDown: nil) == nil)
        #expect(OutboxPlan.phaseReason(conversation: a, [first], now: now, botDown: "fora")
                == "fora; a mensagem sai quando o bot voltar")
        let waiting = OutboxPlan.failed(first, sentence: "o bot recusou", now: now, retry: true)
        #expect(OutboxPlan.phaseReason(conversation: a, [waiting], now: now, botDown: nil)
                == "o bot recusou; tento de novo em 10 s")
        let failed = OutboxPlan.failed(first, sentence: "x", now: now, retry: false)
        #expect(OutboxPlan.phaseReason(conversation: a, [failed], now: now, botDown: nil) == nil)
        #expect(OutboxPlan.phaseReason(conversation: a, [failed, held("a2", a, at: 2)], now: now, botDown: nil)
                == "uma mensagem anterior não foi enviada; as seguintes esperam por ela")
        #expect(OutboxPlan.phaseReason(conversation: b, [first], now: now, botDown: "fora") == nil)
    }
}
