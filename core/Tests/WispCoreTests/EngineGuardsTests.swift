import XCTest
@testable import WispCore

final class EngineGuardsTests: XCTestCase {
    private func fixture() throws -> NSDictionary {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("cli/tests/fixtures/contract/guard-settings.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testSettingsMatchTheBotsFixture() throws {
        let settings = EngineGuards.settings(wispBinary: "/opt/my wisp/bin/wisp") as NSDictionary
        XCTAssertEqual(settings, try fixture())
    }

    func testInstallWritesOnceAndIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("guards-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state/guard-settings-app.json")
        _ = try EngineGuards.install(wispBinary: "/opt/my wisp/bin/wisp", at: url)
        let first = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        _ = try EngineGuards.install(wispBinary: "/opt/my wisp/bin/wisp", at: url)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, first)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary
        XCTAssertEqual(written, try fixture())
    }

    func testTheTelegramBlocksBinaryWinsOverTheRuntime() {
        let layout = RuntimeLayout(bundle: URL(fileURLWithPath: "/nope"), home: URL(fileURLWithPath: "/nope"))
        XCTAssertEqual(EngineGuards.wispBinary(telegramBinary: "/x/wisp", layout: layout), "/x/wisp")
        XCTAssertNil(EngineGuards.wispBinary(telegramBinary: nil, layout: layout))
    }

    func testWithoutTelegramTheAgentStillGetsTheRuntimeBinaryInItsEnvironment() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-nobin-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let wisp = bin.appendingPathComponent("wisp")
        try "#!/bin/sh\n".write(to: wisp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wisp.path)
        let layout = RuntimeLayout(bundle: URL(fileURLWithPath: "/nope"), home: home)
        let resolved = EngineGuards.wispBinary(telegramBinary: nil, layout: layout)
        XCTAssertEqual(resolved, wisp.path)
        let context = AgentInstructions.context(thread: nil, wispBinary: resolved)
        XCTAssertEqual(context.environment, ["WISP_BIN": wisp.path])
        XCTAssertTrue(context.prompt.contains(AgentInstructions.macTools))
    }
}
