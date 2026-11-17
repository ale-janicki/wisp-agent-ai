import XCTest
@testable import WispCore

final class WispSettingsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-settings-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testDefaultIsTheLimeDesign() {
        let colors = WispSettings.default.colors
        XCTAssertEqual(colors.accent.hex, "#A3D65C")
        XCTAssertEqual(colors.accentText.hex, "#C9F08A")
        XCTAssertEqual(colors.userBubble.hex, "#3E4A2A")
        XCTAssertEqual(colors.background.hex, "#111214")
        XCTAssertEqual(colors.surface.hex, "#1A1B1E")
        XCTAssertEqual(colors.surfaceHi.hex, "#232428")
    }

    func testPresetIdsAreUniqueAndIncludeLime() {
        let ids = ThemePreset.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.first, "lime")
        XCTAssertTrue((6...8).contains(ids.count))
    }

    func testUnknownPresetFallsBackToLime() {
        XCTAssertEqual(WispSettings(theme: "nope").colors, WispSettings.default.colors)
        XCTAssertEqual(WispSettings(theme: WispSettings.customTheme, custom: nil).colors, WispSettings.default.colors)
    }

    func testCustomDerivesDependentTokens() {
        let custom = CustomTheme(accent: HexColor(0x000000), background: HexColor(0x101010), surface: HexColor(0x202020))
        let colors = WispSettings(theme: WispSettings.customTheme, custom: custom).colors
        XCTAssertEqual(colors.accent.hex, "#000000")
        XCTAssertEqual(colors.accentText.hex, "#666666")
        XCTAssertEqual(colors.userBubble.hex, "#181818")
        XCTAssertEqual(colors.background.hex, "#101010")
        XCTAssertEqual(colors.surface.hex, "#202020")
        XCTAssertEqual(colors.surfaceHi.hex, "#292929")
    }

    func testStoreMissingFileGivesDefaults() {
        XCTAssertEqual(SettingsStore(directory: dir).settings, .default)
    }

    func testStoreRoundTrip() throws {
        let custom = CustomTheme(accent: HexColor(0x5B9DFF), background: HexColor(0x0E0F12), surface: HexColor(0x17181C))
        let saved = WispSettings(theme: WispSettings.customTheme, custom: custom)
        try SettingsStore(directory: dir).save(saved)
        XCTAssertEqual(SettingsStore(directory: dir).settings, saved)
        let json = try String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"#5B9DFF\""), json)
    }

    func testStoreCorruptFileKeepsBackupAndDefaults() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: dir.appendingPathComponent("settings.json"))
        let store = SettingsStore(directory: dir)
        XCTAssertEqual(store.settings, .default)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("settings.json.bad")), Data("{ nope".utf8))
        XCTAssertTrue(store.lastRecoveryNote?.contains("settings.json.bad") == true)
    }

    func testDashboardOrderDefaultsWhenKeyIsMissing() throws {
        let old = Data(#"{"theme":"blue"}"#.utf8)
        let settings = try JSONDecoder().decode(WispSettings.self, from: old)
        XCTAssertEqual(settings.dashboardOrder, DashboardTileID.defaultOrder)
        XCTAssertEqual(settings.theme, "blue")
    }

    func testDashboardOrderDropsUnknownAndRepeatedAndAppendsMissing() throws {
        let json = Data(#"{"theme":"lime","dashboardOrder":["conversation","ghost","music","conversation"]}"#.utf8)
        let settings = try JSONDecoder().decode(WispSettings.self, from: json)
        XCTAssertEqual(settings.dashboardOrder, ["conversation", "music", "usage", "alerts"])
    }

    func testDashboardOrderStaysNormalizedWhenAssigned() {
        var settings = WispSettings.default
        settings.dashboardOrder = ["alerts"]
        XCTAssertEqual(settings.dashboardOrder, ["alerts", "music", "usage", "conversation"])
    }

    func testDashboardOrderRoundTripsThroughTheStore() throws {
        var settings = WispSettings.default
        settings.dashboardOrder = ["conversation", "alerts", "usage", "music"]
        try SettingsStore(directory: dir).save(settings)
        XCTAssertEqual(SettingsStore(directory: dir).settings.dashboardOrder, ["conversation", "alerts", "usage", "music"])
    }

    func testGraphControlsDefaultWhenKeyIsMissing() throws {
        let settings = try JSONDecoder().decode(WispSettings.self, from: Data(#"{"theme":"lime"}"#.utf8))
        XCTAssertEqual(settings.graph, GraphControls())
    }

    func testGraphControlsFillMissingFieldsAndClampOutOfRange() throws {
        let json = Data(#"{"theme":"lime","graph":{"repel":4,"linkDistance":9000,"textFade":-50}}"#.utf8)
        let graph = try JSONDecoder().decode(WispSettings.self, from: json).graph
        XCTAssertEqual(graph.repel, 4)
        XCTAssertEqual(graph.linkDistance, GraphControls.ranges.linkDistance.upperBound)
        XCTAssertEqual(graph.textFade, GraphControls.ranges.textFade.lowerBound)
        XCTAssertEqual(graph.center, GraphControls().center)
        XCTAssertEqual(graph.nodeSize, GraphControls().nodeSize)
    }

    func testGraphControlsRoundTripThroughTheStore() throws {
        var settings = WispSettings.default
        settings.graph.repel = 3
        settings.graph.nodeSize = 2
        settings.graph.textFade = 1.5
        try SettingsStore(directory: dir).save(settings)
        XCTAssertEqual(SettingsStore(directory: dir).settings.graph, settings.graph)
    }
}
