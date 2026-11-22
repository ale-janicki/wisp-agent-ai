import XCTest
@testable import WispCore

final class BrainCatalogTests: XCTestCase {
    private func catalog() throws -> (BrainVaultFixture, BrainCatalog) {
        let vault = try BrainVaultFixture()
        return (vault, try vault.scan().catalog)
    }

    func testResolvesByFileNameAliasTitleAndPath() throws {
        let (_, catalog) = try catalog()
        XCTAssertEqual(catalog.resolve("apple-pie"), "recipes/apple-pie.md")
        XCTAssertEqual(catalog.resolve("APPLE-PIE"), "recipes/apple-pie.md")
        XCTAssertEqual(catalog.resolve("Tarte"), "recipes/apple-pie.md")
        XCTAssertEqual(catalog.resolve("Home"), "index.md")
        XCTAssertEqual(catalog.resolve("recipes/bread"), "recipes/bread.md")
        XCTAssertEqual(catalog.resolve("./recipes/bread.md"), "recipes/bread.md")
        XCTAssertNil(catalog.resolve("nothing here"))
    }

    func testAccentsFoldWhenThereIsNoExactMatch() throws {
        let catalog = BrainCatalog(notes: [BrainNote(path: "notas/cafe.md", title: "Café")])
        XCTAssertEqual(catalog.resolve("Café"), "notas/cafe.md")
        XCTAssertEqual(catalog.resolve("cafe"), "notas/cafe.md")
        XCTAssertEqual(catalog.resolve("CAFÉ"), "notas/cafe.md")
    }

    func testTheSourceFolderWinsThenTheShallowestPath() {
        let catalog = BrainCatalog(notes: [
            BrainNote(path: "a/deep/x.md"), BrainNote(path: "b/x.md"), BrainNote(path: "x.md"), BrainNote(path: "b/y.md"),
        ])
        XCTAssertEqual(catalog.resolve("x", from: "b/y.md"), "b/x.md")
        XCTAssertEqual(catalog.resolve("x", from: "c/z.md"), "x.md")
    }

    func testSelfHeadingLinkPointsAtTheSourceNote() throws {
        let (_, catalog) = try catalog()
        XCTAssertEqual(catalog.resolve("", from: "index.md"), "index.md")
    }

    func testBacklinksIgnoreSelfLinksAndCodeAndAttachments() throws {
        let (_, catalog) = try catalog()
        XCTAssertEqual(catalog.incoming(of: "recipes/apple-pie.md"), ["index.md", "projects/garden.md", "recipes/bread.md"])
        XCTAssertEqual(catalog.incoming(of: "index.md"), ["recipes/apple-pie.md"])
        XCTAssertTrue(catalog.outgoing(of: "projects/notes.md").contains { $0.target == nil && $0.name == "Missing note" })
        XCTAssertFalse(catalog.outgoing(of: "recipes/bread.md").contains { $0.name == "photo.png" })
    }

    func testTitleAliasesTagsAndStatusAreRead() throws {
        let (_, catalog) = try catalog()
        let note = try XCTUnwrap(catalog.notes["recipes/apple-pie.md"])
        XCTAssertEqual(note.title, "Apple Pie")
        XCTAssertEqual(note.aliases, ["Tarte", "Pie"])
        XCTAssertEqual(note.tags, ["food"])
        XCTAssertEqual(note.status, "active")
    }

    func testScanReusesUnchangedFilesAndSkipsHiddenAndAttachmentFolders() throws {
        let vault = try BrainVaultFixture()
        let first = try vault.scan()
        XCTAssertFalse(first.entries.contains { $0.path.hasPrefix(".obsidian") })
        XCTAssertTrue(first.entries.contains { $0.path == "photo.png" })
        XCTAssertNil(first.catalog.notes["photo.png"])
        let second = try vault.scan(previous: first.catalog)
        XCTAssertEqual(second.read, 0)
        XCTAssertEqual(second.reused, first.catalog.notes.count)
        try vault.put("projects/notes.md", "# Notes changed\n")
        XCTAssertEqual(try vault.scan(previous: first.catalog).read, 1)
    }

    func testInlineTagsComeFromProseOnly() {
        let bytes = Array("# T\n\nwork #alpha and `#nope` and #2024 and a#b\n\n```\n#fenced\n```\n#beta/sub\n".utf8)
        let note = BrainNoteParser.parse(bytes, path: "t.md")
        XCTAssertEqual(note?.inlineTags, ["alpha", "beta/sub"])
    }

    func testBinaryMarkdownIsNotIndexed() {
        XCTAssertNil(BrainNoteParser.parse([0x23, 0x20, 0x00, 0x41], path: "bin.md"))
    }
}
