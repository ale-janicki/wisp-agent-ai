import XCTest
@testable import WispCore

final class LocalWiringTests: XCTestCase {
    private func contract(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("cli/tests/fixtures/contract/\(name)"))
    }

    private func recommendationFixture() throws -> (models: [LocalModel], margin: UInt64, cases: [[String: Any]]) {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try contract("local-recommendation.json")) as? [String: Any])
        let catalog = try XCTUnwrap(object["catalog"] as? [String: Any])
        let models = try JSONDecoder().decode(
            [LocalModel].self, from: try JSONSerialization.data(withJSONObject: try XCTUnwrap(catalog["models"])))
        let margin = try XCTUnwrap((catalog["disk_margin_bytes"] as? NSNumber)?.uint64Value)
        return (models, margin, try XCTUnwrap(object["cases"] as? [[String: Any]]))
    }

    private func pick(_ object: Any?) -> LocalPick? {
        guard let dict = object as? [String: Any] else { return nil }
        let number = { (key: String) -> UInt64? in (dict[key] as? NSNumber)?.uint64Value }
        return LocalPick(
            tag: dict["tag"] as? String ?? "", name: dict["name"] as? String ?? "", sizeBytes: number("size_bytes") ?? 0,
            tokensPerSecond: number("tokens_per_second"), wordsPerSecond: number("words_per_second"),
            reason: dict["reason"] as? String ?? "")
    }

    func testTheRecommendationMatchesThePythonContractFixtureForEveryMac() throws {
        let fixture = try recommendationFixture()
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 10)
        for entry in fixture.cases {
            let input = try XCTUnwrap(entry["input"] as? [String: Any])
            let expect = try XCTUnwrap(entry["expect"] as? [String: Any])
            let name = entry["name"] as? String ?? "?"
            let hardware = HardwareProfile(
                chip: input["chip"] as? String ?? "", totalMemory: (input["memory_bytes"] as? NSNumber)?.uint64Value ?? 0,
                availableMemory: 0, freeDisk: (input["free_disk_bytes"] as? NSNumber)?.uint64Value ?? 0)
            let result = LocalAdvisor.recommend(hardware: hardware, models: fixture.models, diskMargin: fixture.margin)
            XCTAssertEqual(result.best, pick(expect["best"]), name)
            XCTAssertEqual(result.fastest, pick(expect["fastest"]), name)
            XCTAssertEqual(result.notes, expect["notes"] as? [String] ?? [], name)
            XCTAssertEqual(result.chipFamily, expect["chip_family"] as? String, name)
            XCTAssertEqual(result.bandwidthGBs, (expect["bandwidth_gbs"] as? NSNumber)?.uint64Value, name)
        }
    }

    func testTheSwiftBandwidthTableIsTheSameAsThePythonOne() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cli/src/wisp/local/recomendar.py"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #""(M\d(?: \w+)?)": (\d+),"#)
        var python: [String: UInt64] = [:]
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            python[String(source[Range(match.range(at: 1), in: source)!])] = UInt64(source[Range(match.range(at: 2), in: source)!])
        }
        XCTAssertEqual(python, LocalAdvisor.bandwidthGBs)
    }

    func testTheUnknownChipHasNoEstimateButStillGetsAModel() throws {
        let fixture = try recommendationFixture()
        let hardware = HardwareProfile(chip: "Apple M99", totalMemory: 16 << 30, availableMemory: 0, freeDisk: 100_000_000_000)
        let result = LocalAdvisor.recommend(hardware: hardware, models: fixture.models, diskMargin: fixture.margin)
        XCTAssertNil(result.best?.wordsPerSecond)
        XCTAssertEqual(result.best?.tag, "qwen3:8b")
        XCTAssertTrue(result.isSameModel)
    }

    func testThisMacRecommendationUsesTheRealHardwareReading() throws {
        let fixture = try recommendationFixture()
        let result = LocalAdvisor.recommend(hardware: .read(), models: fixture.models, diskMargin: fixture.margin)
        XCTAssertTrue(result.best != nil || !result.notes.isEmpty)
    }

    func testTheLocalEngineIsChosenFromModelosAndTheLocalTableDoesNotLeakIntoIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-lw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = EngineChoice.modelosURL(wispDir: dir)
        try "ativo = \"local\"\n\n[local]\nativo = \"qwen3:8b\"\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(EngineChoice.active(wispDir: dir), .local)
        try "[local]\nativo = \"qwen3:8b\"\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(EngineChoice.active(wispDir: dir), .claude)
        XCTAssertEqual(EngineKind.allCases.map(\.rawValue), ["claude", "codex", "local"])
    }

    func testSwitchingToLocalNeverPrimesButSaysSoAndSwitchingAwayRebuildsFromTheTranscript() {
        let toLocal = EngineResume.plan(kind: .local, lastEngine: "claude", claudeSession: "s", codexSession: nil, lost: false)
        XCTAssertEqual(toLocal, ResumePlan(resume: nil, prime: false, switched: true, linkReason: "new", dropClaudeSession: false))
        let stay = EngineResume.plan(kind: .local, lastEngine: "local", claudeSession: nil, codexSession: nil, lost: true)
        XCTAssertFalse(stay.switched)
        XCTAssertFalse(stay.prime)
        let back = EngineResume.plan(kind: .claude, lastEngine: "local", claudeSession: "s", codexSession: nil, lost: false)
        XCTAssertTrue(back.prime && back.switched && back.dropClaudeSession && back.resume == nil)
        let codexBack = EngineResume.plan(kind: .codex, lastEngine: "local", claudeSession: nil, codexSession: "t", lost: false)
        XCTAssertTrue(codexBack.prime && codexBack.switched)
    }

    func testReadinessParsesWhatTheCliPrintsAndNamesWhatIsMissing() {
        XCTAssertEqual(LocalReadiness.parse(Data(#"{"type":"ready","ready":true}"#.utf8)), LocalReadiness(ready: true))
        let missing = LocalReadiness.parse(Data(#"{"type":"ready","ready":false,"missing":"o mlx-lm não está instalado neste Wisp; atualize o Wisp"}"#.utf8))
        XCTAssertEqual(missing, LocalReadiness(ready: false, missing: "o mlx-lm não está instalado neste Wisp; atualize o Wisp"))
        XCTAssertEqual(
            missing?.note(),
            "a IA local não está pronta (o mlx-lm não está instalado neste Wisp; atualize o Wisp); esta conversa roda no Claude. Ajustes > Modelo resolve.")
        XCTAssertEqual(LocalReadiness.parse(Data(#"{"type":"error","message":"x"}"#.utf8)), LocalReadiness(ready: false, missing: "x"))
        XCTAssertNil(LocalReadiness.parse(Data("nope".utf8)))
    }

    func testStatusSaysWhichModelsAreOnDiskResumableOrBeingDownloaded() throws {
        let json = #"{"models":[],"disk_margin_bytes":1,"backend":{"kind":"mlx","available":true,"running":false,"url":""},"installed":["a","b"],"downloading":["c"],"resumable":["d"],"active":"b"}"#
        let status = try XCTUnwrap(LocalModelStatus.decode(Data(json.utf8)))
        XCTAssertEqual(status.presence(of: "a"), .downloaded)
        XCTAssertEqual(status.presence(of: "b"), .inUse)
        XCTAssertEqual(status.presence(of: "c"), .downloading)
        XCTAssertEqual(status.presence(of: "d"), .resumable)
        XCTAssertEqual(status.presence(of: "e"), .absent)
        let old = try XCTUnwrap(LocalModelStatus.decode(Data(#"{"models":[],"disk_margin_bytes":1,"backend":{"kind":"mlx","available":true,"running":false,"url":""},"installed":[],"active":""}"#.utf8)))
        XCTAssertEqual(old.presence(of: "a"), .absent)
    }

    func testReadinessWithoutTheWispBinaryIsNotReady() {
        XCTAssertFalse(LocalReadiness.check(wispBinary: nil, environment: [:]).ready)
    }

    func testReadinessRunsTheRealCommandAndReadsItsAnswer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-lw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("wisp")
        try "#!/bin/sh\necho \"$@\" > \(dir.path)/argv\necho '{\"type\":\"ready\",\"ready\":false,\"missing\":\"o modelo x não está baixado\"}'\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let readiness = LocalReadiness.check(wispBinary: script.path, environment: [:])
        XCTAssertEqual(readiness, LocalReadiness(ready: false, missing: "o modelo x não está baixado"))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("argv"), encoding: .utf8), "local ready\n")
    }

    func testTheThinkingSettingIsDecodedFromTheCatalogOutputAndDefaultsToOff() throws {
        let status = try XCTUnwrap(LocalModelStatus.decode(try contract("local-catalog.json")))
        XCTAssertFalse(status.pensar)
        let on = String(decoding: try contract("local-catalog.json"), as: UTF8.self).replacingOccurrences(of: #""pensar": false"#, with: #""pensar": true"#)
        XCTAssertTrue(try XCTUnwrap(LocalModelStatus.decode(Data(on.utf8))).pensar)
        let old = String(decoding: try contract("local-catalog.json"), as: UTF8.self).replacingOccurrences(of: #""pensar": false, "#, with: "")
        XCTAssertFalse(try XCTUnwrap(LocalModelStatus.decode(Data(old.utf8))).pensar)
    }

    func testTheModelCatalogCarriesWhetherToolsAreReliableAndOlderOutputStillDecodes() throws {
        let status = try XCTUnwrap(LocalModelStatus.decode(try contract("local-catalog.json")))
        XCTAssertEqual(status.models.first { $0.tag == "qwen3:4b" }?.toolsReliable, false)
        XCTAssertEqual(status.models.first { $0.tag == "qwen3:8b" }?.toolsReliable, true)
        let old = #"{"tag":"x","name":"X","params":"1B","size_bytes":1,"memory_bytes":2,"tier":"pequeno","context_tokens":8192,"speed":"rapido","limitations":"l"}"#
        XCTAssertEqual(try JSONDecoder().decode(LocalModel.self, from: Data(old.utf8)).toolsReliable, true)
    }

    func testThePlanSkipsWhatIsAlreadyThere() {
        XCTAssertEqual(
            LocalAISetup.steps(modelInstalled: false, tag: "m"), [.pull("m"), .use("m"), .selectEngine])
        XCTAssertEqual(LocalAISetup.steps(modelInstalled: true, tag: "m"), [.use("m"), .selectEngine])
    }

    private actor Log {
        var steps: [LocalAIStep] = []
        func add(_ step: LocalAIStep) { steps.append(step) }
    }

    func testTheOneButtonFlowRunsEveryStepInOrderAndSwitchesLast() async {
        let log = Log()
        let plan = LocalAISetup.steps(modelInstalled: false, tag: "qwen3:8b")
        let outcome = await LocalAISetup.run(plan) { step in
            await log.add(step)
            return .done
        }
        XCTAssertEqual(outcome, .done)
        let ran = await log.steps
        XCTAssertEqual(ran, [.pull("qwen3:8b"), .use("qwen3:8b"), .selectEngine])
    }

    func testAFailedPullLeavesTheEngineAndTheModelUntouched() async {
        for failing in [LocalAIStep.pull("m")] {
            let log = Log()
            let outcome = await LocalAISetup.run(LocalAISetup.steps(modelInstalled: false, tag: "m")) { step in
                await log.add(step)
                return step == failing ? .failed("sem rede") : .done
            }
            XCTAssertEqual(outcome, .failed("sem rede"))
            let ran = await log.steps
            XCTAssertFalse(ran.contains(.selectEngine))
            XCTAssertFalse(ran.contains(.use("m")))
        }
    }

    func testACancelledDownloadStopsTheFlowWithoutSwitching() async {
        let log = Log()
        let outcome = await LocalAISetup.run(LocalAISetup.steps(modelInstalled: false, tag: "m")) { step in
            await log.add(step)
            return step == .pull("m") ? .cancelled : .done
        }
        XCTAssertEqual(outcome, .cancelled)
        let ran = await log.steps
        XCTAssertEqual(ran, [.pull("m")])
    }

    func testAFailedEngineSwitchIsReportedAndTheEarlierStepsAreNotUndoneSilently() async {
        let outcome = await LocalAISetup.run([.use("m"), .selectEngine]) { step in step == .selectEngine ? .failed("harness") : .done }
        XCTAssertEqual(outcome, .failed("harness"))
    }

    func testAMacWithoutAppleSiliconIsToldSoAndNeverStartsTheFlow() throws {
        let fixture = try recommendationFixture()
        let intel = HardwareProfile(chip: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz", totalMemory: 32 << 30, availableMemory: 0, freeDisk: 500_000_000_000)
        let eight = try XCTUnwrap(fixture.models.first { $0.tag == "qwen3:8b" })
        XCTAssertEqual(LocalAISetup.preflight(model: eight, hardware: intel, diskMargin: fixture.margin, installed: false), LocalAdvisor.needsAppleSilicon)
        XCTAssertTrue(LocalAdvisor.needsAppleSilicon.contains("wisp local backend openai"))
        let result = LocalAdvisor.recommend(hardware: intel, models: fixture.models, diskMargin: fixture.margin)
        XCTAssertNil(result.best)
        XCTAssertEqual(result.notes, [LocalAdvisor.needsAppleSilicon])
        XCTAssertTrue(LocalAdvisor.appleSilicon("Apple M4 Pro"))
        XCTAssertFalse(LocalAdvisor.appleSilicon(""))
    }

    func testPythonAndSwiftSayTheSameThingWithoutAppleSilicon() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cli/src/wisp/local/arch.py"), encoding: .utf8)
        let joined = LocalAdvisor.needsAppleSilicon
        XCTAssertTrue(source.contains("o MLX local precisa de um Mac com Apple silicon e este não tem; aponte para um servidor compatível com OpenAI"))
        XCTAssertTrue(joined.hasSuffix("ou use o Claude ou o Codex, que rodam na assinatura"))
    }

    func testPreflightRefusesWhatDoesNotFitBeforeAnythingIsDownloaded() throws {
        let fixture = try recommendationFixture()
        let big = try XCTUnwrap(fixture.models.first { $0.tag == "qwen3:32b" })
        let small = HardwareProfile(chip: "Apple M4", totalMemory: 16 << 30, availableMemory: 0, freeDisk: 100_000_000_000)
        XCTAssertEqual(LocalAISetup.preflight(model: big, hardware: small, diskMargin: fixture.margin, installed: false), "O Qwen3 32B não cabe na memória deste Mac.")
        let eight = try XCTUnwrap(fixture.models.first { $0.tag == "qwen3:8b" })
        let tightDisk = HardwareProfile(chip: "Apple M4", totalMemory: 16 << 30, availableMemory: 0, freeDisk: 6_000_000_000)
        XCTAssertTrue(LocalAISetup.preflight(model: eight, hardware: tightDisk, diskMargin: fixture.margin, installed: false)?.contains("Falta espaço") == true)
        XCTAssertNil(LocalAISetup.preflight(model: eight, hardware: small, diskMargin: fixture.margin, installed: false))
    }
}
