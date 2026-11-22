import XCTest
@testable import WispCore

final class BrainNavigationTests: XCTestCase {
    func testHistoryGoesBackForwardAndDropsTheForwardBranchOnANewVisit() {
        var history = BrainHistory()
        history.visit("a.md")
        history.visit("b.md")
        history.visit("c.md")
        XCTAssertEqual(history.back(), "b.md")
        XCTAssertEqual(history.back(), "a.md")
        XCTAssertNil(history.back())
        XCTAssertEqual(history.forward(), "b.md")
        history.visit("d.md")
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.entries, ["a.md", "b.md", "d.md"])
        history.visit("d.md")
        XCTAssertEqual(history.entries.count, 3)
    }

    func testHistoryFollowsRenamesAndForgetsDeletions() {
        var history = BrainHistory()
        ["x/a.md", "y.md", "x/b.md"].forEach { history.visit($0) }
        history.rename("x", to: "z")
        XCTAssertEqual(history.entries, ["z/a.md", "y.md", "z/b.md"])
        history.forget("z")
        XCTAssertEqual(history.entries, ["y.md"])
        XCTAssertEqual(history.current, "y.md")
    }

    func testBookmarksToggleRenameForgetAndPersistPerBrain() throws {
        var marks = BrainBookmarks()
        marks.toggle("a.md")
        marks.toggle("f/b.md")
        marks.toggle("a.md")
        XCTAssertEqual(marks.paths, ["f/b.md"])
        marks.rename("f", to: "g")
        XCTAssertEqual(marks.paths, ["g/b.md"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bm-\(UUID().uuidString)/brain-bookmarks.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try marks.save(to: file, root: "/tmp/brain-one")
        try BrainBookmarks(paths: ["other.md"]).save(to: file, root: "/tmp/brain-two")
        XCTAssertEqual(BrainBookmarks.load(from: file, root: "/tmp/brain-one").paths, ["g/b.md"])
        XCTAssertEqual(BrainBookmarks.load(from: file, root: "/tmp/brain-two").paths, ["other.md"])
        marks.forget("g")
        XCTAssertTrue(marks.paths.isEmpty)
    }

    func testSwitcherRanksTitlesAliasesAndPathsAndFoldsAccents() {
        let entries = [
            BrainSwitcherEntry(path: "recipes/apple-pie.md", title: "Apple Pie", aliases: ["Tarte"]),
            BrainSwitcherEntry(path: "projects/pineapple-plan.md", title: "Pineapple Plan"),
            BrainSwitcherEntry(path: "notas/cafe.md", title: "Café"),
            BrainSwitcherEntry(path: "deep/folder/unrelated.md", title: "Unrelated"),
        ]
        XCTAssertEqual(BrainSwitcher.rank("apple", in: entries).map(\.path), ["recipes/apple-pie.md", "projects/pineapple-plan.md"])
        XCTAssertEqual(BrainSwitcher.rank("tarte", in: entries).first?.alias, "Tarte")
        XCTAssertEqual(BrainSwitcher.rank("cafe", in: entries).first?.path, "notas/cafe.md")
        XCTAssertEqual(BrainSwitcher.rank("ap pl", in: entries).first?.path, "projects/pineapple-plan.md")
        XCTAssertEqual(BrainSwitcher.rank("folder", in: entries).first?.path, "deep/folder/unrelated.md")
        XCTAssertTrue(BrainSwitcher.rank("zzz", in: entries).isEmpty)
    }

    func testSwitcherWithoutAQueryListsTheMostRecent() {
        let entries = [BrainSwitcherEntry(path: "old.md", title: "Old", modified: 1), BrainSwitcherEntry(path: "new.md", title: "New", modified: 9)]
        XCTAssertEqual(BrainSwitcher.rank("", in: entries).map(\.path), ["new.md", "old.md"])
    }

    func testCompletionFindsLinkAndTagContexts() {
        let link = BrainCompletion.context(in: "see [[Ap", cursor: 8)
        XCTAssertEqual(link, BrainCompletionContext(kind: .link, query: "Ap", range: NSRange(location: 6, length: 2)))
        XCTAssertNil(BrainCompletion.context(in: "see [[Ap|al", cursor: 11))
        XCTAssertNil(BrainCompletion.context(in: "see [[done]] x", cursor: 14))
        let tag = BrainCompletion.context(in: "line one\nwork #pro", cursor: 18)
        XCTAssertEqual(tag, BrainCompletionContext(kind: .tag, query: "pro", range: NSRange(location: 15, length: 3)))
        XCTAssertNil(BrainCompletion.context(in: "a#b", cursor: 3))
        XCTAssertNil(BrainCompletion.context(in: "# heading", cursor: 9))
    }

    func testCompletionInsertsTheShortNameOrAnAliasForm() throws {
        let vault = try BrainVaultFixture()
        let catalog = try vault.scan().catalog
        XCTAssertEqual(BrainCompletion.linkText(for: BrainSwitcherResult(path: "recipes/apple-pie.md", title: "Apple Pie", alias: nil, score: 1), catalog: catalog), "apple-pie")
        XCTAssertEqual(BrainCompletion.linkText(for: BrainSwitcherResult(path: "recipes/apple-pie.md", title: "Apple Pie", alias: "Tarte", score: 1), catalog: catalog), "apple-pie|Tarte")
        XCTAssertEqual(BrainCompletion.tags("fo", in: ["food": 3, "form": 1, "x": 9]), ["food", "form"])
    }

    func testTreeSortsFoldersFirstThenNaturalByName() {
        let entries = [
            BrainFileEntry(path: "b.md", isFolder: false), BrainFileEntry(path: "Zeta", isFolder: true), BrainFileEntry(path: "alpha", isFolder: true),
            BrainFileEntry(path: "alpha/n10.md", isFolder: false), BrainFileEntry(path: "alpha/n2.md", isFolder: false),
            BrainFileEntry(path: "A.md", isFolder: false),
        ]
        let collapsed = BrainTree.rows(entries: entries, expanded: [])
        XCTAssertEqual(collapsed.map(\.name), ["alpha", "Zeta", "A", "b"])
        let open = BrainTree.rows(entries: entries, expanded: ["alpha"])
        XCTAssertEqual(open.map(\.name), ["alpha", "n2", "n10", "Zeta", "A", "b"])
        XCTAssertEqual(open.map(\.depth), [0, 1, 1, 0, 0, 0])
        XCTAssertEqual(BrainTree.ancestors(of: "a/b/c.md"), ["a/b", "a"])
        XCTAssertEqual(BrainTree.uniquePath("alpha/n2.md", existing: ["alpha/n2.md", "alpha/n2 2.md"]), "alpha/n2 3.md")
        XCTAssertEqual(BrainFileKind.of("x/Draw.excalidraw.md"), .drawing)
        XCTAssertEqual(BrainFileKind.of("a.PNG"), .image)
    }

    func testBacklinksCarryTheContextLine() throws {
        let vault = try BrainVaultFixture()
        let catalog = try vault.scan().catalog
        let found = BrainBacklinks.find(for: "recipes/apple-pie.md", catalog: catalog, files: BrainFiles(root: vault.path))
        let bread = try XCTUnwrap(found.first { $0.path == "recipes/bread.md" })
        XCTAssertEqual(bread.contexts, [BrainBacklinkContext(line: 2, text: "Uses [[apple-pie#Crust|the crust]] and ![[photo.png]].")])
        XCTAssertEqual(found.count, 3)
        let outgoing = BrainBacklinks.outgoing(text: "[[Tarte]] [[nope]] [[Tarte#X]]", source: "index.md", catalog: catalog)
        XCTAssertEqual(outgoing.map(\.target), ["recipes/apple-pie.md", nil, "recipes/apple-pie.md"])
    }

    func testSearchClientDecodesTheCliJson() {
        let json = Data(#"[{"path":"a/b.md","title":"B","snippet":"x … y","score":1.25}]"#.utf8)
        XCTAssertEqual(BrainSearchClient.decode(json), [BrainSearchHit(path: "a/b.md", title: "B", snippet: "x … y", score: 1.25)])
        XCTAssertNil(BrainSearchClient.decode(Data("nope".utf8)))
        XCTAssertEqual(BrainSearchClient.arguments(root: "/r", query: "q w", limit: 5), ["brain", "search", "q w", "--root", "/r", "--limit", "5"])
    }
}
