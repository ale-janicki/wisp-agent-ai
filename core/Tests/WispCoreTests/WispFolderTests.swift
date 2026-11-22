import XCTest
@testable import WispCore

final class WispFolderTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private func fixture() throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("cli/tests/fixtures/contract/wisp-folder-layout.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["cases"] as? [[String: Any]])
    }

    private func fill(_ value: String) -> String { value.replacingOccurrences(of: "{home}", with: home.path) }

    func testTheResolverMatchesTheSharedContract() throws {
        for item in try fixture() {
            let name = item["name"] as? String ?? "?"
            let environment = (item["env"] as? [String: String] ?? [:]).mapValues(fill)
            let expect = (item["expect"] as? [String: String] ?? [:]).mapValues(fill)
            let config = WispFolder.configURL(environment: environment, home: home)
            XCTAssertEqual(config.path, expect["config_file"], name)
            try? FileManager.default.removeItem(at: home.appendingPathComponent(".config"))
            if let raw = item["config"] as? [String: Any] {
                try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: raw).write(to: config)
            }
            let layout = WispFolder.layout(environment: environment, home: home)
            let found: [String: String] = [
                "root": layout.root.path, "conversas": layout.conversas.path, "reunioes": layout.reunioes.path,
                "brain": layout.brain.path, "modelos_pasta": layout.modelosPasta.path, "anexos": layout.anexos.path, "skills": layout.skills.path,
                "ferramentas": layout.ferramentas.path, "logs": layout.logs.path, "agente": layout.agente.path,
                "guardrails": layout.guardrails.path, "modelos": layout.modelos.path,
            ]
            for (key, value) in found { XCTAssertEqual(value, expect[key], "\(name): \(key)") }
            for created in [config] { try? FileManager.default.removeItem(at: created) }
        }
    }

    func testMeetingsFollowTheWispFolderUnlessConfigured() throws {
        let config = home.appendingPathComponent("c.json")
        try JSONSerialization.data(withJSONObject: ["wisp_dir": "~/Dados"]).write(to: config)
        let environment = ["WISP_CONFIG": config.path]
        XCTAssertEqual(RecordingFolder.root(configured: nil, environment: environment, home: home).path, home.path + "/Dados/reunioes")
        XCTAssertEqual(RecordingFolder.root(configured: "~/Gravacoes", environment: environment, home: home).path, home.path + "/Gravacoes")
    }

    func testTheSettingsListCoversEveryFolderOfTheLayout() {
        let names = WispFolder.contents.map(\.name)
        XCTAssertEqual(names, ["conversas/", "reunioes/", "brain/", "modelos/", "anexos/", "skills/", "ferramentas/", "logs/",
                               "agente.md", "guardrails.toml", "modelos.toml"])
        XCTAssertTrue(WispFolder.contents.allSatisfy { !$0.detail.isEmpty })
    }

    func testPendingMeetingsCountsTheOldFolderOnlyWhenTheWispFolderMoved() throws {
        let old = home.appendingPathComponent("Wisp/reunioes", isDirectory: true)
        for name in ["a", "b", "MOVIDO.txt", ".wisp-part-c"] {
            try FileManager.default.createDirectory(at: old.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        XCTAssertEqual(WispFolder.pendingMeetings(environment: ["WISP_CONFIG": home.appendingPathComponent("none.json").path], home: home), 0)
        let moved = home.appendingPathComponent("moved.json")
        try JSONSerialization.data(withJSONObject: ["wisp_dir": "~/Dados"]).write(to: moved)
        XCTAssertEqual(WispFolder.pendingMeetings(environment: ["WISP_CONFIG": moved.path], home: home), 2)
        let inside = home.appendingPathComponent("inside.json")
        try JSONSerialization.data(withJSONObject: ["wisp_dir": "~/Wisp/reunioes"]).write(to: inside)
        XCTAssertEqual(WispFolder.pendingMeetings(environment: ["WISP_CONFIG": inside.path], home: home), 0)
    }

    func testTheSameFolderInAnotherCaseIsNotPending() throws {
        let old = home.appendingPathComponent("Wisp/reunioes/a", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: home.appendingPathComponent("wisp").path), "case-sensitive volume")
        let config = home.appendingPathComponent("case.json")
        try JSONSerialization.data(withJSONObject: ["wisp_dir": "~/wisp"]).write(to: config)
        XCTAssertEqual(WispFolder.pendingMeetings(environment: ["WISP_CONFIG": config.path], home: home), 0)
        XCTAssertTrue(WispFolder.isSameFolder(home.appendingPathComponent("Wisp"), home.appendingPathComponent("wisp")))
        XCTAssertTrue(WispFolder.isInside(home.appendingPathComponent("WISP/reunioes/a"), home.appendingPathComponent("wisp")))
    }

    func testAnOldMeetingsFolderThatIsALinkIsNotOffered() throws {
        let external = home.appendingPathComponent("Disco/reunioes", isDirectory: true)
        try FileManager.default.createDirectory(at: external.appendingPathComponent("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Wisp"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Wisp/reunioes"), withDestinationURL: external)
        let config = home.appendingPathComponent("moved.json")
        try JSONSerialization.data(withJSONObject: ["wisp_dir": "~/Dados"]).write(to: config)
        XCTAssertEqual(WispFolder.pendingMeetings(environment: ["WISP_CONFIG": config.path], home: home), 0)
    }
}
