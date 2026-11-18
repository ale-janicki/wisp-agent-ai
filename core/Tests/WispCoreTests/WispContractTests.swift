import XCTest
@testable import WispCore

/// The Python CLI's contract fixtures (cli/tests/fixtures/contract) must decode with the real Swift parsers.
final class WispContractTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cli/tests/fixtures/contract/\(name).json")
    }

    private func data(_ name: String) throws -> Data { try Data(contentsOf: fixture(name)) }

    func testTopicStatusDecodes() throws { _ = try TelegramTopics.parseStatus(data("topic-status")) }
    func testTopicListDecodes() throws { _ = try TelegramTopics.parseTopics(data("topic-list")) }
    func testTopicNewDecodes() throws { _ = try TelegramTopics.parseCreated(data("topic-new")) }
    func testTopicClaimDecodes() throws { _ = try TelegramTopics.parseClaim(data("topic-claim")) }

    func testProfileLoadsWithUser() throws {
        let profile = try ProfileLoader.load(from: fixture("profile"))
        XCTAssertEqual(profile.persona.name, "Ada")
        XCTAssertEqual(profile.persona.user, "Rita")
    }
}
