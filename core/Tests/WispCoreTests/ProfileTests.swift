import XCTest
@testable import WispCore

final class ProfileTests: XCTestCase {
    private func tempFile(_ contents: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("profile.json")
        if let contents { try contents.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    func testLoadsProfile() throws {
        let url = try tempFile("""
        {"persona":{"name":"Wisp","language":"pt-BR"},
         "agent":{"cwd":"~","statusPrefix":"STATUS ·"}}
        """)
        let profile = try ProfileLoader.load(from: url)
        XCTAssertEqual(profile.persona.name, "Wisp")
        XCTAssertEqual(profile.persona.language, "pt-BR")
        XCTAssertNil(profile.persona.avatar)
        XCTAssertEqual(profile.agent.cwd, "~")
        XCTAssertEqual(profile.agent.statusPrefix, "STATUS ·")
        XCTAssertNil(profile.agent.model)
        XCTAssertNil(profile.agent.claudePath)
    }

    func testMissingFileGivesDefault() throws {
        let url = try tempFile(nil)
        let profile = try ProfileLoader.load(from: url)
        XCTAssertEqual(profile.persona.name, "Wisp")
        XCTAssertEqual(profile.persona.language, "en")
        XCTAssertEqual(profile.agent.cwd, "~")
        XCTAssertNil(profile.agent.statusPrefix)
    }

    func testInvalidJSONThrowsWithPath() throws {
        let url = try tempFile("{ not json")
        XCTAssertThrowsError(try ProfileLoader.load(from: url)) { error in
            guard case ProfileError.invalid(let path, _) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertEqual(path, url.path)
            XCTAssertTrue(error.localizedDescription.contains(url.path))
        }
    }

    func testDanglingSymlinkThrows() throws {
        let url = try tempFile(nil)
        try FileManager.default.createSymbolicLink(
            atPath: url.path,
            withDestinationPath: url.deletingLastPathComponent().appendingPathComponent("nope.json").path)
        XCTAssertThrowsError(try ProfileLoader.load(from: url)) { error in
            guard case ProfileError.missingTarget(let path) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertEqual(path, url.path)
            XCTAssertTrue(error.localizedDescription.contains(url.path))
        }
    }

    func testIgnoresUnknownBlocksKey() throws {
        let url = try tempFile("""
        {"persona":{"name":"A","language":"en"},"agent":{"cwd":"~"},"blocks":[{"x":1}]}
        """)
        XCTAssertEqual(try ProfileLoader.load(from: url).persona.name, "A")
    }

    func testLoadsAlertsBlockCommand() throws {
        let url = try tempFile("""
        {"persona":{"name":"A","language":"en"},"agent":{"cwd":"~"},"blocks":{"alerts":{"list":"alerts list --json"},"todos":{"list":"x"}}}
        """)
        let profile = try ProfileLoader.load(from: url)
        XCTAssertEqual(profile.blocks?.alerts?.list, "alerts list --json")
        XCTAssertNil(profile.blocks?.alerts?.resolve)
    }

    func testExpandsTilde() {
        XCTAssertEqual(expandTilde("~/x"), NSHomeDirectory() + "/x")
        XCTAssertEqual(expandTilde("~"), NSHomeDirectory())
        XCTAssertEqual(expandTilde("/a/b"), "/a/b")
    }
}
