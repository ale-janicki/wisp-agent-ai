import XCTest
@testable import WispCore

final class LocalModelsTests: XCTestCase {
    private func model(_ tag: String = "m", size: UInt64 = 5_200_000_000, memory: UInt64 = 6_700_000_000) -> LocalModel {
        LocalModel(
            tag: tag, name: tag, params: "8B", sizeBytes: size, memoryBytes: memory, tier: "pequeno", contextTokens: 8192,
            speed: "rapido", limitations: "x")
    }

    private func mac(memoryGB: UInt64, diskGB: UInt64) -> HardwareProfile {
        HardwareProfile(chip: "Apple M2", totalMemory: memoryGB * 1_000_000_000, availableMemory: 0, freeDisk: diskGB * 1_000_000_000)
    }

    private func contract(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("cli/tests/fixtures/contract/\(name)"))
    }

    func testFitFollowsTheShareOfUnifiedMemory() {
        let m = model(memory: 6_700_000_000)
        XCTAssertEqual(ModelFit.assess(m, on: mac(memoryGB: 16, diskGB: 100), diskMargin: 5_000_000_000).level, .fits)
        let tight = ModelFit.assess(m, on: mac(memoryGB: 10, diskGB: 100), diskMargin: 5_000_000_000)
        XCTAssertEqual(tight.level, .tight)
        XCTAssertTrue(tight.note.contains("feche outros apps"))
        XCTAssertTrue(tight.canInstall)
        let none = ModelFit.assess(m, on: mac(memoryGB: 8, diskGB: 100), diskMargin: 5_000_000_000)
        XCTAssertEqual(none.level, .doesNotFit)
        XCTAssertFalse(none.canInstall)
    }

    func testTheBoundariesAreInclusiveOfTheShare() {
        let hardware = mac(memoryGB: 20, diskGB: 100)
        XCTAssertEqual(ModelFit.assess(model(memory: 10_000_000_000), on: hardware, diskMargin: 0).level, .fits)
        XCTAssertEqual(ModelFit.assess(model(memory: 10_000_000_001), on: hardware, diskMargin: 0).level, .tight)
        XCTAssertEqual(ModelFit.assess(model(memory: 15_000_000_000), on: hardware, diskMargin: 0).level, .tight)
        XCTAssertEqual(ModelFit.assess(model(memory: 15_000_000_001), on: hardware, diskMargin: 0).level, .doesNotFit)
    }

    func testAnUnreadableMemoryNeverFits() {
        XCTAssertEqual(ModelFit.assess(model(), on: mac(memoryGB: 0, diskGB: 100), diskMargin: 0).level, .doesNotFit)
    }

    func testDiskNeedsSizePlusMarginAndIsSkippedForInstalledModels() {
        let m = model(size: 5_200_000_000, memory: 6_000_000_000)
        let low = mac(memoryGB: 32, diskGB: 10)
        let fit = ModelFit.assess(m, on: low, diskMargin: 5_000_000_000)
        XCTAssertEqual(fit.level, .fits)
        XCTAssertEqual(fit.diskShortBy, 200_000_000)
        XCTAssertFalse(fit.canInstall)
        XCTAssertNil(ModelFit.assess(m, on: mac(memoryGB: 32, diskGB: 11), diskMargin: 5_000_000_000).diskShortBy)
        XCTAssertNil(ModelFit.assess(m, on: low, diskMargin: 5_000_000_000, installed: true).diskShortBy)
        XCTAssertNil(ModelFit.assess(m, on: mac(memoryGB: 32, diskGB: 10), diskMargin: 4_800_000_000).diskShortBy)
    }

    func testTheRealReadingOfThisMac() {
        let hardware = HardwareProfile.read()
        XCTAssertFalse(hardware.chip.isEmpty)
        XCTAssertGreaterThan(hardware.totalMemory, 1_000_000_000)
        XCTAssertGreaterThan(hardware.freeDisk, 0)
        XCTAssertLessThanOrEqual(hardware.availableMemory, hardware.totalMemory)
    }

    func testAvailableMemoryCountsTheReclaimablePages() {
        let counts = VMPageCounts(
            pageSize: 16384, free: 10, active: 99, inactive: 20, speculative: 3, wired: 99, compressor: 99, purgeable: 7,
            external: 99, internalPages: 99)
        XCTAssertEqual(HardwareProfile.availableMemory(counts), 40 * 16384)
    }

    func testTheAppDecodesWhatTheCliPrints() throws {
        let status = try XCTUnwrap(LocalModelStatus.decode(try contract("local-catalog.json")))
        XCTAssertGreaterThanOrEqual(status.models.count, 4)
        XCTAssertEqual(status.diskMarginBytes, 5_000_000_000)
        let eight = try XCTUnwrap(status.models.first { $0.tag == "qwen3:8b" })
        XCTAssertEqual(eight.sizeBytes, 4_623_782_544)
        XCTAssertGreaterThan(eight.memoryBytes, eight.sizeBytes)
        XCTAssertEqual(eight.tierLabel, "Pequeno")
        XCTAssertEqual(status.backend, BackendStatus(kind: "mlx", available: false, running: false))
        XCTAssertEqual(status.active, "")
    }

    func testTheAppRendersTheLocalEngineStreamLikeClaudes() throws {
        let text = String(decoding: try contract("local-engine-events.jsonl"), as: UTF8.self)
        let events = text.split(separator: "\n").flatMap { ClaudeStreamDecoder.decode(line: String($0)) }
        XCTAssertEqual(events.first, .initialized(sessionId: "c1", model: "qwen3:8b", subscription: true))
        XCTAssertTrue(events.contains(.thinking))
        XCTAssertTrue(events.contains(.text("vou ler")))
        XCTAssertTrue(events.contains { if case .toolUse(let name, _) = $0 { return name == "read_file" } else { return false } })
        XCTAssertTrue(events.contains(.toolResult(toolUseId: "toolu_local_id0", isError: false, text: "conteúdo das notas")))
        XCTAssertEqual(events.last, .result(sessionId: "c1", text: "pronto", isError: false, denials: []))
        XCTAssertFalse(events.contains { if case .malformed = $0 { return true } else { return false } })
    }

    func testASavedClaudeTabOpensTheModelTab() {
        XCTAssertEqual(SettingsSectionMigration.current("claude"), "model")
        XCTAssertEqual(SettingsSectionMigration.current("notices"), "notices")
        XCTAssertNil(SettingsSectionMigration.current(nil))
    }

    func testJobLinesDecode() {
        XCTAssertEqual(
            ModelJobEvent.decode(line: #"{"type":"progress","status":"downloading","completed":5,"total":10}"#),
            .progress(status: "downloading", completed: 5, total: 10))
        XCTAssertEqual(ModelJobEvent.decode(line: #"{"type":"done","tag":"x"}"#), .done)
        XCTAssertEqual(ModelJobEvent.decode(line: #"{"type":"error","message":"falta espaço"}"#), .failed("falta espaço"))
        XCTAssertNil(ModelJobEvent.decode(line: "not json"))
    }

    func testLineStreamYieldsLinesAndReportsTheExit() async throws {
        let lines = LockedLines()
        let result = await LineStream().run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo um; echo dois >&2; printf tres; exit 3"]
        ) { lines.add($0) }
        guard case .success(let finished) = result else { return XCTFail("launch failed") }
        XCTAssertEqual(lines.all, ["um", "tres"])
        XCTAssertEqual(finished.status, 3)
        XCTAssertEqual(finished.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines), "dois")
    }

    func testCancelKillsTheWholeGroup() async throws {
        let stream = LineStream()
        let lines = LockedLines()
        let started = Date()
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            stream.cancel()
        }
        let result = await stream.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo pronto; sleep 30 & sleep 30"]
        ) { lines.add($0) }
        guard case .success = result else { return XCTFail("launch failed") }
        XCTAssertTrue(stream.wasCancelled)
        XCTAssertEqual(lines.all, ["pronto"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
