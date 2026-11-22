import XCTest
@testable import WispCore

final class BrainSafetyTests: XCTestCase {
    private func outside() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testWritingThroughAnInsideSymlinkKeepsTheLinkAndUpdatesTheTarget() throws {
        let vault = try BrainVaultFixture()
        try FileManager.default.createSymbolicLink(atPath: vault.root.appendingPathComponent("alias.md").path, withDestinationPath: "recipes/bread.md")
        try BrainFiles(root: vault.path).write("changed", to: "alias.md")
        let attributes = try FileManager.default.attributesOfItem(atPath: vault.root.appendingPathComponent("alias.md").path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try vault.text("recipes/bread.md"), "changed")
    }

    func testSymlinkPointingOutsideIsReadOnlyAndNeverWritten() throws {
        let vault = try BrainVaultFixture()
        let elsewhere = try outside()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let target = elsewhere.appendingPathComponent("secret.md")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: vault.root.appendingPathComponent("link.md"), withDestinationURL: target)
        let files = BrainFiles(root: vault.path)
        XCTAssertNotNil(files.writeProblem("link.md"))
        XCTAssertThrowsError(try files.write("overwritten", to: "link.md"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        let attributes = try FileManager.default.attributesOfItem(atPath: vault.root.appendingPathComponent("link.md").path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    func testRewriteKeepsModeAndExtendedAttributes() throws {
        let vault = try BrainVaultFixture()
        let path = vault.root.appendingPathComponent("recipes/bread.md").path
        chmod(path, 0o640)
        XCTAssertEqual(setxattr(path, "user.wisp.test", "v", 1, 0, 0), 0)
        try BrainFiles(root: vault.path).write("new", to: "recipes/bread.md")
        var info = stat()
        stat(path, &info)
        XCTAssertEqual(info.st_mode & 0o777, 0o640)
        XCTAssertEqual(getxattr(path, "user.wisp.test", nil, 0, 0, 0), 1)
    }

    func testConfinementRefusesHiddenParentEscapesAndBadNames() throws {
        let vault = try BrainVaultFixture()
        let elsewhere = try outside()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: vault.root.appendingPathComponent("portal"), withDestinationURL: elsewhere)
        let files = BrainFiles(root: vault.path)
        for bad in [".git/config", ".obsidian/app.json", "recipes/.hidden.md", "portal/x.md", "../x.md", "/abs.md", "", "a//b.md"] {
            XCTAssertThrowsError(try files.url(bad), bad)
        }
        for bad in ["a:b.md", "a\\b.md"] { XCTAssertThrowsError(try files.createNote(bad), bad) }
        XCTAssertThrowsError(try files.move("recipes/bread.md", to: "portal/bread.md"))
        XCTAssertThrowsError(try files.move("recipes/bread.md", to: ".git/bread.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("x.md").path))
    }

    func testInvalidUtf8AndNulFilesAreReadOnlyAndNeverWritten() throws {
        let vault = try BrainVaultFixture()
        let bad = Data([0x23, 0x20, 0xFF, 0xFE, 0x0A])
        let nul = Data([0x61, 0x00, 0x62])
        try bad.write(to: vault.root.appendingPathComponent("bad.md"))
        try nul.write(to: vault.root.appendingPathComponent("nul.md"))
        let files = BrainFiles(root: vault.path)
        for name in ["bad.md", "nul.md"] {
            XCTAssertNotNil(try files.inspect(name).readOnlyReason)
            XCTAssertThrowsError(try files.write("x", to: name))
            XCTAssertThrowsError(try files.readStrict(name))
        }
        XCTAssertEqual(try Data(contentsOf: vault.root.appendingPathComponent("bad.md")), bad)
        XCTAssertEqual(try Data(contentsOf: vault.root.appendingPathComponent("nul.md")), nul)
        XCTAssertNil(try files.inspect("index.md").readOnlyReason)
    }

    func testRenameFindsLinksBeyondTheScannerPrefixInLargeNotes() throws {
        let vault = try BrainVaultFixture()
        let filler = String(repeating: "filler line without links\n", count: 6000)
        try vault.put("projects/long.md", "# Long\n\n" + filler + "\nFinally [[recipes/bread]] here.\n")
        let scan = try vault.scan()
        XCTAssertGreaterThan(scan.entries.first { $0.path == "projects/long.md" }?.size ?? 0, Int64(BrainNoteParser.readLimit))
        XCTAssertTrue(scan.catalog.incoming(of: "recipes/bread.md").contains("projects/long.md") == false)
        let plan = try BrainRefactor.plan(root: vault.path, scan: scan, from: "recipes/bread.md", to: "recipes/loaf.md")
        try BrainRefactor.apply(plan, root: vault.path)
        XCTAssertTrue(try vault.text("projects/long.md").hasSuffix("Finally [[recipes/loaf]] here.\n"))
    }

    func testUndownloadedNotesAreReportedAndTheListIsNotComplete() throws {
        let vault = try BrainVaultFixture()
        var scan = try vault.scan()
        scan.entries.append(BrainFileEntry(path: "cloud/later.md", isFolder: false, dataless: true))
        let plan = try BrainRefactor.plan(root: vault.path, scan: scan, from: "recipes/bread.md", to: "recipes/loaf.md")
        XCTAssertEqual(plan.undownloaded, ["cloud/later.md"])
        XCTAssertFalse(plan.isComplete)
    }

    func testSymlinkedNotesAreSkippedNotRewritten() throws {
        let vault = try BrainVaultFixture()
        let elsewhere = try outside()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let target = elsewhere.appendingPathComponent("ext.md")
        try Data("see [[recipes/bread]]\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: vault.root.appendingPathComponent("ext.md"), withDestinationURL: target)
        let plan = try BrainRefactor.plan(root: vault.path, scan: vault.scan(), from: "recipes/bread.md", to: "recipes/loaf.md")
        try BrainRefactor.apply(plan, root: vault.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "see [[recipes/bread]]\n")
    }

    func testApplyFreshRefusesAPlanMadeStaleByANewLink() throws {
        let vault = try BrainVaultFixture()
        let plan = try BrainRefactor.plan(root: vault.path, scan: vault.scan(), from: "recipes/bread.md", to: "recipes/loaf.md")
        try vault.put("late.md", "added later [[recipes/bread]]\n")
        XCTAssertThrowsError(try BrainRefactor.applyFresh(plan, root: vault.path)) { XCTAssertEqual($0 as? BrainFilesError, .stale("recipes/bread.md")) }
        XCTAssertTrue(vault.exists("recipes/bread.md"))
        XCTAssertEqual(try vault.text("late.md"), "added later [[recipes/bread]]\n")
    }

    func testApplyKeepsFileModeAndLeavesNoTemporariesInsideTheBrain() throws {
        let vault = try BrainVaultFixture()
        chmod(vault.root.appendingPathComponent("projects/garden.md").path, 0o600)
        let plan = try BrainRefactor.plan(root: vault.path, scan: vault.scan(), from: "recipes/bread.md", to: "recipes/loaf.md")
        try BrainRefactor.applyFresh(plan, root: vault.path)
        var info = stat()
        stat(vault.root.appendingPathComponent("projects/garden.md").path, &info)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let walker = FileManager.default.enumerator(atPath: vault.path)
        while let name = walker?.nextObject() as? String { XCTAssertFalse(name.contains("wisp-"), name) }
    }

    func testRecoveryNamesAreUniqueShortAndFailuresAreReported() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 5)
        let first = try XCTUnwrap(BrainRecovery.save("a", named: "x.md", in: folder, now: now))
        let second = try XCTUnwrap(BrainRecovery.save("b", named: "x.md", in: folder, now: now))
        XCTAssertNotEqual(first, second)
        let long = String(repeating: "deep/", count: 80) + "note.md"
        let name = try XCTUnwrap(BrainRecovery.save("c", named: long, in: folder, now: now)).lastPathComponent
        XCTAssertLessThan(name.count, 100)
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        XCTAssertNil(BrainRecovery.save("lost?", named: "x.md", in: blocker.appendingPathComponent("sub")))
    }

    func testConflictMarkersAreDetectedOnlyWhenBothSidesAreThere() {
        XCTAssertTrue(BrainMerge.hasMarkers("a\n\(BrainMerge.mineMarker)\nx\n=======\ny\n\(BrainMerge.theirsMarker)\nb"))
        XCTAssertFalse(BrainMerge.hasMarkers("a\n\(BrainMerge.mineMarker)\nonly"))
        XCTAssertFalse(BrainMerge.hasMarkers("plain\n======="))
    }

    func testOnlyHttpHttpsAndMailtoOpenFileIsRevealedAndTheRestRefused() throws {
        XCTAssertEqual(BrainLinkPolicy.decide(try XCTUnwrap(URL(string: "https://a.example"))), .open)
        XCTAssertEqual(BrainLinkPolicy.decide(try XCTUnwrap(URL(string: "HTTP://a.example"))), .open)
        XCTAssertEqual(BrainLinkPolicy.decide(try XCTUnwrap(URL(string: "mailto:a@b.example"))), .open)
        XCTAssertEqual(BrainLinkPolicy.decide(try XCTUnwrap(URL(string: "file:///etc/hosts"))), .reveal)
        XCTAssertEqual(BrainLinkPolicy.decide(try XCTUnwrap(URL(string: "someapp://run?x=1"))), .refuse)
        XCTAssertEqual(BrainLinkPolicy.decide(try XCTUnwrap(URL(string: "javascript:alert(1)"))), .refuse)
        XCTAssertEqual(BrainLinkPolicy.decide(try XCTUnwrap(URL(string: "relative/path"))), .refuse)
    }

    func testTaskToggleRefusesWhenTheLineChanged() {
        let text = "- [ ] buy milk\n- [ ] other\n"
        XCTAssertEqual(BrainTasks.toggle(in: text, line: 0, expected: "- [ ] buy milk"), "- [x] buy milk\n- [ ] other\n")
        XCTAssertNil(BrainTasks.toggle(in: text, line: 0, expected: "- [ ] something else"))
        XCTAssertNotNil(BrainTasks.toggle(in: "> - [ ] quoted\n", line: 0, expected: "- [ ] quoted"))
    }

    func testRenderModelKeepsTheRawTaskLine() {
        let model = BrainMarkdown.parse("# T\n\n- [ ] one\n")
        guard case .list(_, _, let items) = model.nodes[1].block else { return XCTFail("no list") }
        XCTAssertEqual(items[0].raw, "- [ ] one")
    }

    func testDailyHeadingIsEnglishAndOrdinalsAreReal() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        XCTAssertEqual(BrainTemplate.render("# {{date:YYYY-MM-DD dddd}}", title: "t", date: date, calendar: calendar), "# 2026-01-01 Thursday")
        XCTAssertEqual(MomentFormat.string(from: date, format: "MMMM Do", calendar: calendar), "January 1st")
        XCTAssertEqual([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 30].map(MomentFormat.ordinal), ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "30th"])
    }
}
