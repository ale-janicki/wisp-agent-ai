import XCTest
@testable import WispCore

final class TabSettingsTests: XCTestCase {
    func testConversationShowsEngineModelAndPermission() {
        XCTAssertEqual(TabSettings.blocks(forTab: "conversation"), [.engine, .model, .permission, .telegram])
    }

    func testEachRelatedTabShowsOnlyItsOwnSection() {
        XCTAssertEqual(TabSettings.blocks(forTab: "brain"), [.brain])
        XCTAssertEqual(TabSettings.blocks(forTab: "agenda"), [.agenda])
        XCTAssertEqual(TabSettings.blocks(forTab: "meetings"), [.meetings])
        XCTAssertEqual(TabSettings.blocks(forTab: "myMac"), [.macControl])
        XCTAssertEqual(TabSettings.blocks(forTab: "music"), [.integrations])
    }

    func testTabsWithoutSettingsGetNoGear() {
        for tab in ["home", "tasks", "reminders", "routines", "clipboard", "settings", "memory", "unknown"] {
            XCTAssertFalse(TabSettings.hasSettings(tab), tab)
            XCTAssertNil(TabSettings.fullSection(forTab: tab), tab)
        }
    }

    func testEveryTabWithBlocksLinksToAFullSection() {
        let valid: Set<String> = ["appearance", "model", "notices", "integrations", "general", "about"]
        for tab in ["conversation", "brain", "agenda", "meetings", "myMac", "music"] {
            XCTAssertTrue(TabSettings.hasSettings(tab))
            XCTAssertTrue(valid.contains(TabSettings.fullSection(forTab: tab) ?? ""), tab)
        }
    }
}
