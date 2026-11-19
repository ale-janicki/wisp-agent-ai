import XCTest
@testable import WispCore

final class WispContractTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cli/tests/fixtures/contract/\(name).json")
    }

    private func data(_ name: String) throws -> Data { try Data(contentsOf: fixture(name)) }

    func testTopicStatusDecodes() throws { _ = try TelegramTopics.parseStatus(data("topic-status")) }
    func testTopicListDecodes() throws { _ = try TelegramTopics.parseTopics(data("topic-list")) }
    func testTopicSharedDecodes() throws { _ = try TelegramTopics.parseShared(data("topic-new")) }

    func testProfileLoadsWithUser() throws {
        let profile = try ProfileLoader.load(from: fixture("profile"))
        XCTAssertEqual(profile.persona.name, "Ada")
        XCTAssertEqual(profile.persona.user, "Rita")
    }
}
