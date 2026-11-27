import XCTest
@testable import WispCore

final class CommandsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("tests"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ body: String, executable: Bool = true) throws {
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }

    func testScansExecutableFilesOnlyWithFirstComment() throws {
        try write("zeta", "#!/bin/bash\n\n## Faz a zeta\nls\n")
        try write("alpha", "#!/usr/bin/env python3\nprint(1)\n")
        try write("plain.md", "# doc\n", executable: false)
        try write(".hidden", "#!/bin/sh\n")
        let entries = CommandScanner.scan(dirs: [dir.path])
        XCTAssertEqual(entries.map(\.name), ["alpha", "zeta"])
        XCTAssertNil(entries[0].detail)
        XCTAssertEqual(entries[1].detail, "Faz a zeta")
    }

    func testFirstCommentRules() {
        XCTAssertEqual(CommandScanner.firstComment(in: "#!/bin/sh\n#   hello  \necho"), "hello")
        XCTAssertEqual(CommandScanner.firstComment(in: "# only\n"), "only")
        XCTAssertNil(CommandScanner.firstComment(in: "#!/bin/sh\necho hi\n# late"))
        XCTAssertEqual(CommandScanner.firstComment(in: "#!/bin/sh\n#\n# second\n"), "second")
    }

    func testMissingDirIsEmpty() {
        XCTAssertTrue(CommandScanner.scan(dirs: ["/nonexistent-wisp-dir"]).isEmpty)
    }
}
