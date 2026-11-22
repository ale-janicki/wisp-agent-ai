import XCTest
@testable import WispCore

final class BrainDailyTests: XCTestCase {
    private let locale = Locale(identifier: "en_US_POSIX")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private let date = Date(timeIntervalSince1970: 1_767_225_600 + 14 * 3600 + 5 * 60)

    func testMomentTokensBecomeDateFormats() {
        XCTAssertEqual(MomentFormat.string(from: date, format: "YYYY-MM-DD", locale: locale, calendar: calendar), "2026-01-01")
        XCTAssertEqual(MomentFormat.string(from: date, format: "DD/MM/YY dddd", locale: locale, calendar: calendar), "01/01/26 Thursday")
        XCTAssertEqual(MomentFormat.string(from: date, format: "[Week of] MMMM D", locale: locale, calendar: calendar), "Week of January 1")
        XCTAssertEqual(MomentFormat.string(from: date, format: "HH:mm", locale: locale, calendar: calendar), "14:05")
    }

    func testDailyPathUsesFolderAndFormat() {
        XCTAssertEqual(BrainDailyConfig(folder: "daily").path(for: date, locale: locale, calendar: calendar), "daily/2026-01-01.md")
        XCTAssertEqual(BrainDailyConfig(folder: "", format: "YYYYMMDD").path(for: date, locale: locale, calendar: calendar), "20260101.md")
    }

    func testConfigIsInferredFromTheFolderTheBrainAlreadyUses() throws {
        let vault = try BrainVaultFixture()
        let notes = try vault.scan().catalog.notes.keys.sorted()
        let config = BrainDailyConfig.load(root: vault.path, notes: notes)
        XCTAssertEqual(config.folder, "daily")
        XCTAssertEqual(config.format, "YYYY-MM-DD")
        XCTAssertEqual(config.template, "templates/daily.md")
        XCTAssertEqual(BrainDailyConfig.templatesFolder(root: vault.path, notes: notes), "templates")
    }

    func testObsidianConfigWinsAndIsOnlyRead() throws {
        let vault = try BrainVaultFixture()
        try vault.put(".obsidian/daily-notes.json", #"{"folder":"/journal/","format":"DD.MM.YYYY","template":"templates/meeting"}"#)
        try vault.put(".obsidian/templates.json", #"{"folder":"templates"}"#)
        let before = try vault.text(".obsidian/daily-notes.json")
        let config = BrainDailyConfig.load(root: vault.path, notes: try vault.scan().catalog.notes.keys.sorted())
        XCTAssertEqual(config, BrainDailyConfig(folder: "journal", format: "DD.MM.YYYY", template: "templates/meeting.md"))
        XCTAssertEqual(try vault.text(".obsidian/daily-notes.json"), before)
    }

    func testDefaultsWhenTheBrainHasNoHints() {
        XCTAssertEqual(BrainDailyConfig.load(root: "/nonexistent-\(UUID().uuidString)", notes: ["a.md"]), BrainDailyConfig())
    }

    func testTemplateVariables() {
        let out = BrainTemplate.render("date: {{date:YYYY-MM-DD}}\n# {{title}} {{ time }} {{unknown}} {{date:dddd}}", title: "Today", date: date, locale: locale, calendar: calendar)
        XCTAssertEqual(out, "date: 2026-01-01\n# Today 14:05 {{unknown}} Thursday")
    }
}
