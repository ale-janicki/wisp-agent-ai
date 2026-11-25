import XCTest
@testable import WispCore

final class CompletionTests: XCTestCase {
    private var root: URL!
    private var home: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("completion-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        for dir in ["home/repos", "home/Reports", "home/My Docs", "home/.config", "home/work/app", "home/work/lib"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["home/readme.md", "home/.zshrc", "home/work/notes.txt", "home/work/Notes.md", "home/work/a b.txt"] {
            fm.createFile(atPath: root.appendingPathComponent(file).path, contents: Data())
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func context(cwd: String? = nil) -> CompletionContext {
        var live = CompletionContext.live(cwd: cwd ?? home.path, home: home.path, path: { "" })
        live.executables = { ["git", "grep", "ls", "Gimp"] }
        return live
    }

    private func complete(_ line: String, cursor: Int? = nil, cwd: String? = nil) -> [Completion] {
        CompletionEngine.complete(line: line, cursor: cursor ?? line.utf16.count, context: context(cwd: cwd))
    }

    private func inserts(_ line: String, cwd: String? = nil) -> [String] { complete(line, cwd: cwd).map(\.insertText) }

    // MARK: Tokenizer

    func testTokenIsTheWordUnderTheCursor() {
        let token = CompletionEngine.token(in: "cd repos", cursor: 8)
        XCTAssertEqual(token.value, "repos")
        XCTAssertEqual(token.range, 3..<8)
        XCTAssertFalse(token.isCommand)
        XCTAssertEqual(token.command, "cd")
    }

    func testCursorMidLineReadsOnlyUpToIt() {
        let token = CompletionEngine.token(in: "ls /usr/local more", cursor: 7)
        XCTAssertEqual(token.value, "/usr")
        XCTAssertEqual(token.range, 3..<7)
    }

    func testAfterASpaceTheWordIsEmpty() {
        let token = CompletionEngine.token(in: "ls ", cursor: 3)
        XCTAssertEqual(token.value, "")
        XCTAssertEqual(token.range, 3..<3)
        XCTAssertFalse(token.isCommand)
    }

    func testQuotesAndEscapesBelongToTheWord() {
        XCTAssertEqual(CompletionEngine.token(in: "cd My\\ Do", cursor: 9).value, "My Do")
        let quoted = CompletionEngine.token(in: "cd \"My Do", cursor: 9)
        XCTAssertEqual(quoted.value, "My Do")
        XCTAssertEqual(quoted.openQuote, "\"")
        XCTAssertEqual(quoted.range, 3..<9)
        XCTAssertNil(CompletionEngine.token(in: "cd 'a b' x", cursor: 10).openQuote)
    }

    func testCommandPositionAfterOperators() {
        for line in ["gi", "ls | gi", "ls; gi", "ls && gi", "ls || gi", "ls &gi"] {
            let token = CompletionEngine.token(in: line, cursor: line.utf16.count)
            XCTAssertTrue(token.isCommand, line)
            XCTAssertEqual(token.value, "gi", line)
        }
        XCTAssertFalse(CompletionEngine.token(in: "echo gi", cursor: 7).isCommand)
    }

    func testAnOperatorInsideQuotesIsText() {
        let token = CompletionEngine.token(in: "echo 'a; b", cursor: 10)
        XCTAssertFalse(token.isCommand)
        XCTAssertEqual(token.value, "a; b")
    }

    // MARK: Commands

    func testCommandsComeFromPathAndBuiltins() {
        XCTAssertEqual(inserts("g"), ["git ", "grep "])
        let kinds = Dictionary(uniqueKeysWithValues: complete("e").map { ($0.display, $0.kind) })
        XCTAssertEqual(kinds["echo"], .builtin)
        XCTAssertEqual(complete("gr").first?.kind, .exec)
        XCTAssertEqual(complete("expo").map(\.display), ["export"])
        XCTAssertEqual(complete("so").map(\.display), ["source"])
    }

    func testCommandMatchIsCaseInsensitiveOnlyWhenNothingMatchesExactly() {
        XCTAssertEqual(complete("gi").map(\.display), ["git"])
        XCTAssertEqual(complete("GI").map(\.display), ["Gimp", "git"])
    }

    func testEmptyCommandWordOffersNothing() {
        XCTAssertTrue(complete("").isEmpty)
        XCTAssertEqual(complete("ls | gr").map(\.display), ["grep"])
    }

    // MARK: Arguments

    func testDirectoriesGetASlashAndComeFirst() {
        XCTAssertEqual(complete("ls re").map(\.insertText), ["repos/", "readme.md "])
        XCTAssertEqual(complete("cd rep").map(\.insertText), ["repos/"])
        XCTAssertEqual(complete("cd rep").first?.kind, .dir)
        XCTAssertEqual(complete("ls work/n").first?.kind, .file)
    }

    func testCdOnlyOffersDirectories() {
        XCTAssertEqual(inserts("cd re"), ["repos/"])
        XCTAssertEqual(inserts("pushd re"), ["repos/"])
        XCTAssertEqual(inserts("rmdir re"), ["repos/"])
        XCTAssertEqual(Set(inserts("ls re")), ["repos/", "readme.md "])
        XCTAssertEqual(inserts("echo hi && cd re"), ["repos/"])
    }

    func testHiddenFilesOnlyWhenTheWordStartsWithADot() {
        XCTAssertFalse(inserts("ls ").contains { $0.hasPrefix(".") })
        XCTAssertTrue(inserts("ls .").contains(".config/"))
        XCTAssertTrue(inserts("ls .z").contains(".zshrc "))
    }

    func testPrefixFirstThenCaseInsensitive() {
        XCTAssertEqual(inserts("ls work/N"), ["work/Notes.md "])
        XCTAssertEqual(inserts("ls work/no"), ["work/notes.txt "])
        XCTAssertEqual(inserts("ls work/NO"), ["work/Notes.md ", "work/notes.txt "])
        XCTAssertEqual(inserts("cd REPO"), ["Reports/", "repos/"])
    }

    func testTildeAbsoluteAndParentPaths() {
        XCTAssertEqual(inserts("cd ~/rep", cwd: "/"), ["~/repos/"])
        XCTAssertEqual(inserts("cd \(home.path)/wo"), ["\(home.path)/work/"])
        XCTAssertEqual(inserts("cd ../../ho", cwd: home.appendingPathComponent("work").path), ["../../home/"])
        XCTAssertEqual(inserts("cd ../repos/", cwd: home.appendingPathComponent("work").path), [])
        XCTAssertEqual(inserts("cd ~"), ["~/"])
        XCTAssertEqual(inserts("cd work/"), ["work/app/", "work/lib/"])
    }

    func testRelativeToTheCwd() {
        let work = home.appendingPathComponent("work").path
        XCTAssertEqual(inserts("cd a", cwd: work), ["app/"])
        XCTAssertEqual(inserts("ls n", cwd: work), ["notes.txt "])
    }

    func testSpacesAndSpecialsAreEscaped() {
        XCTAssertEqual(inserts("cd My"), ["My\\ Docs/"])
        XCTAssertEqual(complete("cd My").first?.display, "My Docs/")
        XCTAssertEqual(inserts("ls work/a\\ "), ["work/a\\ b.txt "])
        XCTAssertEqual(CompletionEngine.escape("a(b)&c$d"), "a\\(b\\)\\&c\\$d")
    }

    func testInsideAQuoteTheTextIsNotEscaped() {
        XCTAssertEqual(inserts("cd \"My"), ["\"My Docs/"])
        XCTAssertEqual(inserts("ls \"work/a "), ["\"work/a b.txt\" "])
    }

    func testReplaceRangeCoversTheWholeWord() {
        let found = complete("echo x && cd re")
        XCTAssertEqual(found.first?.replaceRange, 13..<15)
        let quoted = complete("cd \"My")
        XCTAssertEqual(quoted.first?.replaceRange, 3..<6)
    }

    private func specialsDirectory() throws -> String {
        let dir = root.appendingPathComponent("special")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["it's", "a$b", "~tilde", "q\"x", "back`tick", "line\nbreak"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        return dir.path
    }

    func testInsideDoubleQuotesTheDangerousCharactersAreEscaped() throws {
        let cwd = try specialsDirectory()
        XCTAssertEqual(inserts("ls \"a", cwd: cwd), ["\"a\\$b\" "])
        XCTAssertEqual(inserts("ls \"q", cwd: cwd), ["\"q\\\"x\" "])
        XCTAssertEqual(inserts("ls \"back", cwd: cwd), ["\"back\\`tick\" "])
        XCTAssertEqual(CompletionEngine.escapeInQuote("a\\b", quote: "\""), "a\\\\b")
    }

    func testInsideSingleQuotesAQuoteIsClosedEscapedAndReopened() throws {
        let cwd = try specialsDirectory()
        XCTAssertEqual(inserts("ls 'it", cwd: cwd), ["'it'\\''s' "])
        XCTAssertEqual(inserts("ls 'a", cwd: cwd), ["'a$b' "])
    }

    func testNewlineAndALeadingTildeAreEscaped() throws {
        let cwd = try specialsDirectory()
        XCTAssertEqual(inserts("ls line", cwd: cwd), ["line\\\nbreak "])
        XCTAssertEqual(inserts("ls \\~", cwd: cwd), ["\\~tilde "])
        XCTAssertEqual(CompletionEngine.escape("a~b", leadingTilde: true), "a~b")
        XCTAssertEqual(CompletionEngine.escape("~a", leadingTilde: true), "\\~a")
    }

    func testCursorMidWordReplacesTheWholeWord() {
        let found = complete("cd repos now", cursor: 5)
        XCTAssertEqual(found.map(\.insertText), ["repos/"])
        XCTAssertEqual(found.first?.replaceRange, 3..<8, "the tail after the cursor goes too")
        let file = complete("ls rea", cursor: 5)
        XCTAssertEqual(file.map(\.insertText), ["readme.md "])
        XCTAssertEqual(file.first?.replaceRange, 3..<6)
        XCTAssertEqual(complete("ls re ", cursor: 5).first?.replaceRange, 3..<5, "a space ends the word")
    }

    func testTheExecutablesAreScannedOnceAndAFolderThatChangedIsReadAgain() throws {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func addTool(_ name: String) throws {
            let file = bin.appendingPathComponent(name)
            FileManager.default.createFile(atPath: file.path, contents: Data())
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        try addTool("alpha")
        let cache = ExecutablesCache(maxAge: 30, scansInBackground: false)
        let start = Date()
        XCTAssertEqual(cache.names(path: bin.path, now: start), [], "nothing is read on the caller's thread: the first answer is empty")
        cache.refresh(path: bin.path, now: start)
        XCTAssertEqual(cache.names(path: bin.path, now: start.addingTimeInterval(5)), ["alpha"])
        try addTool("beta")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: bin.path)
        XCTAssertEqual(cache.names(path: bin.path, now: start.addingTimeInterval(5)), ["alpha"], "fresh: no rescan")
        cache.refresh(path: bin.path, now: start.addingTimeInterval(40))
        XCTAssertEqual(Set(cache.names(path: bin.path, now: start.addingTimeInterval(41))), ["alpha", "beta"])
    }

    func testCommonPrefix() {
        XCTAssertEqual(CompletionEngine.commonPrefix(complete("ls re")), "re")
        XCTAssertEqual(CompletionEngine.commonPrefix(complete("ls work/")), "work/")
        XCTAssertEqual(CompletionEngine.commonPrefix(complete("cd rep")), "repos/")
        XCTAssertEqual(CompletionEngine.commonPrefix(complete("g")), "g")
    }
}
