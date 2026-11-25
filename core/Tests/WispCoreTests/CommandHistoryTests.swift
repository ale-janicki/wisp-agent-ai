import XCTest
@testable import WispCore

final class CommandHistoryTests: XCTestCase {
    func testZshExtendedWithMultiLineEntries() {
        let text = ": 1700000000:0;ls -la\n: 1700000001:0;echo a\\\necho b\n: 1700000002:3;git status\n"
        XCTAssertEqual(HistoryParser.parse(text), ["ls -la", "echo a\necho b", "git status"])
    }

    func testZshEscapedBackslashAtTheEndDoesNotContinue() {
        XCTAssertEqual(HistoryParser.parse(": 1:0;echo \\\\\n: 2:0;next\n"), ["echo \\\\", "next"])
    }

    func testBashPlainLinesSkipTimestampLines() {
        XCTAssertEqual(HistoryParser.parse("#1700000000\nls\n#1700000001\npwd\n\n"), ["ls", "pwd"])
        XCTAssertEqual(HistoryParser.detect("ls\npwd\n"), .plain)
    }

    func testFishYaml() {
        let text = "- cmd: echo hi\n  when: 1700000000\n- cmd: a\\nb\n  when: 1\n  paths:\n    - x\n- cmd: c:\\\\d\n  when: 2\n"
        XCTAssertEqual(HistoryParser.parse(text), ["echo hi", "a\nb", "c:\\d"])
    }

    func testConsecutiveDuplicatesGoButFarOnesStay() {
        XCTAssertEqual(HistoryParser.parse("ls\nls\npwd\nls\n"), ["ls", "pwd", "ls"])
    }

    func testZshMetafiedBytesAreRestored() {
        let data = Data([0x65, 0x63, 0x68, 0x6F, 0x20, 0xE2, 0x83, 0xA0, 0x83, 0xB3, 0x0A])
        XCTAssertEqual(HistoryParser.parse(HistoryParser.unmetafy(data)), ["echo –"])
    }

    func testLoadsAFileAndMissingFileIsEmpty() throws {
        let path = NSTemporaryDirectory() + "wisp-hist-\(UUID().uuidString)"
        try ": 1:0;one\n: 2:0;two\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(HistoryParser.load(path: path, metafied: true), ["one", "two"])
        XCTAssertNil(HistoryParser.load(path: path + "-missing", metafied: true), "a missing file is nil, not an empty history")
    }

    func testBashAndFishFilesAreNotUnmetafied() throws {
        let path = NSTemporaryDirectory() + "wisp-hist-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "echo NÃO\necho 😃\n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(HistoryParser.load(path: path, metafied: false), ["echo NÃO", "echo 😃"])
        try "- cmd: echo NÃO\n  when: 1\n- cmd: echo 😃\n  when: 2\n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(HistoryParser.load(path: path, metafied: false), ["echo NÃO", "echo 😃"])
    }

    func testOnlyTheTailOfABigFileIsReadAndItsCutFirstLineGoes() throws {
        let path = NSTemporaryDirectory() + "wisp-hist-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let lines = (0..<2000).map { "command number \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let loaded = try XCTUnwrap(HistoryParser.load(path: path, metafied: false, tailBytes: 1000))
        XCTAssertEqual(loaded.last, "command number 1999")
        XCTAssertLessThan(loaded.count, 100)
        XCTAssertTrue(loaded.allSatisfy { $0.hasPrefix("command number ") && Int($0.dropFirst(15)) != nil }, "the cut line must be gone")
    }

    func testSeedIsClaimedOnceAndReleasedWhenTheFileWasMissing() {
        let history = CommandHistory()
        XCTAssertTrue(history.claimSeed())
        XCTAssertFalse(history.claimSeed(), "one read in flight")
        history.releaseSeed()
        XCTAssertTrue(history.claimSeed(), "the first path failed: the real one may try")
        history.seed(with: ["a"])
        XCTAssertFalse(history.claimSeed())
        XCTAssertEqual(history.entries, ["a"])
    }

    func testDefaultFiles() {
        XCTAssertEqual(HistoryParser.defaultFile(shellName: "zsh", home: "/h"), "/h/.zsh_history")
        XCTAssertEqual(HistoryParser.defaultFile(shellName: "bash", home: "/h"), "/h/.bash_history")
        XCTAssertEqual(HistoryParser.defaultFile(shellName: "fish", home: "/h"), "/h/.local/share/fish/fish_history")
        XCTAssertNil(HistoryParser.defaultFile(shellName: "nu", home: "/h"))
    }

    func testAppendDedupesTrimsAndRingKeepsTheNewest() {
        let history = CommandHistory(capacity: 3)
        for command in ["a", "a", "  ", "b", "c", "d"] { history.append(command) }
        XCTAssertEqual(history.entries, ["b", "c", "d"])
    }

    func testSeedGoesInFrontOfWhatWasAddedAndHappensOnce() {
        let history = CommandHistory()
        history.append("new")
        history.seed(with: ["old1", "old2"])
        history.seed(with: ["ignored"])
        XCTAssertEqual(history.entries, ["old1", "old2", "new"])
        XCTAssertTrue(history.isSeeded)
    }

    func testPrefixNavigationBackForwardAndDraft() {
        let entries = ["git status", "ls", "git diff", "echo hi"]
        var nav = HistoryNavigator()
        XCTAssertEqual(nav.back(entries: entries, current: "git"), "git diff")
        XCTAssertEqual(nav.back(entries: entries, current: "git diff"), "git status")
        XCTAssertNil(nav.back(entries: entries, current: "git status"), "nothing older")
        XCTAssertEqual(nav.forward(entries: entries, current: "git status"), "git diff")
        XCTAssertEqual(nav.forward(entries: entries, current: "git diff"), "git", "past the newest the draft comes back")
        XCTAssertFalse(nav.isNavigating)
        XCTAssertNil(nav.forward(entries: entries, current: "git"))
    }

    func testEmptyPrefixWalksEverything() {
        let entries = ["one", "two"]
        var nav = HistoryNavigator()
        XCTAssertEqual(nav.back(entries: entries, current: ""), "two")
        XCTAssertEqual(nav.back(entries: entries, current: "two"), "one")
        XCTAssertEqual(nav.forward(entries: entries, current: "one"), "two")
        XCTAssertEqual(nav.forward(entries: entries, current: "two"), "")
    }

    func testSearchNewestFirstSubstringBeforeSubsequenceNoRepeats() {
        let history = CommandHistory()
        for command in ["echo one", "git status", "echo two", "git status", "grep -rn stat ."] { history.append(command) }
        XCTAssertEqual(history.search("").first, "grep -rn stat .")
        XCTAssertEqual(history.search("status"), ["git status"])
        XCTAssertEqual(history.search("ECHO"), ["echo two", "echo one"])
        XCTAssertEqual(history.search("gtst"), ["git status"])
        XCTAssertEqual(history.search("echo two"), ["echo two"])
        XCTAssertEqual(history.search("zzz"), [])
        XCTAssertEqual(history.search("", limit: 2).count, 2)
    }
}

final class CommandSyntaxTests: XCTestCase {
    private func kinds(_ text: String, programs: Set<String> = ["git", "ls", "echo", "sudo"]) -> [(String, CommandSyntax.Kind)] {
        let units = Array(text.utf16)
        return CommandSyntax.spans(text, isProgram: { programs.contains($0) }, isPrefixOfProgram: { word in programs.contains { $0.hasPrefix(word) } })
            .map { (String(decoding: units[$0.range], as: UTF16.self), $0.kind) }
    }

    func testCommandFlagStringAndPath() {
        let result = kinds("git commit -m \"a b\" ./x")
        XCTAssertEqual(result.map(\.0), ["git", "-m", "\"a b\"", "./x"])
        XCTAssertEqual(result.map(\.1), [.command(resolved: true), .flag, .string, .path])
    }

    func testUnknownCommandIsRedAndAPartialWordIsNot() {
        XCTAssertEqual(kinds("nope x").first?.1, .command(resolved: false))
        XCTAssertEqual(kinds("gi").first?.1, .command(resolved: true), "still typing git")
        XCTAssertEqual(kinds("gi ").first?.1, .command(resolved: false))
    }

    func testPipesAndSudoStartANewCommand() {
        let result = kinds("ls | nope; sudo git")
        XCTAssertEqual(result.map(\.1), [.command(resolved: true), .command(resolved: false), .command(resolved: true), .command(resolved: true)])
    }

    func testAssignmentBeforeTheCommandIsSkipped() {
        XCTAssertEqual(kinds("FOO=1 ls").map(\.0), ["ls"])
    }
}
