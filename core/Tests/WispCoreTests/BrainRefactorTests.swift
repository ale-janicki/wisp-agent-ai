import XCTest
@testable import WispCore

final class BrainRefactorTests: XCTestCase {
    private func rename(_ vault: BrainVaultFixture, _ from: String, _ to: String) throws -> BrainMovePlan {
        let plan = try BrainRefactor.plan(root: vault.path, scan: vault.scan(), from: from, to: to)
        try BrainRefactor.apply(plan, root: vault.path)
        return plan
    }

    func testRenamingANoteRewritesPathAndNameLinksButKeepsHeadingAndAlias() throws {
        let vault = try BrainVaultFixture()
        let plan = try rename(vault, "recipes/bread.md", "recipes/sourdough.md")
        XCTAssertFalse(vault.exists("recipes/bread.md"))
        XCTAssertTrue(vault.exists("recipes/sourdough.md"))
        XCTAssertEqual(try vault.text("projects/garden.md"), "# Garden\n\nPlant [[../recipes/sourdough]] herbs. Also [[Tarte]].\n")
        XCTAssertEqual(plan.linkCount, 1)
        XCTAssertEqual(plan.fileCount, 1)
    }

    func testAliasAndTitleLinksNeedNoRewriteBecauseTheyStillResolve() throws {
        let vault = try BrainVaultFixture()
        let plan = try rename(vault, "recipes/apple-pie.md", "recipes/tart.md")
        XCTAssertEqual(try vault.text("projects/garden.md"), "# Garden\n\nPlant [[../recipes/bread]] herbs. Also [[Tarte]].\n")
        XCTAssertEqual(try vault.text("index.md"), "# Home\n\nSee [[Apple Pie]] and [[projects/garden]].\n")
        XCTAssertTrue(try vault.text("recipes/bread.md").contains("[[tart#Crust|the crust]]"))
        XCTAssertTrue(plan.edits.contains { $0.oldPath == "recipes/bread.md" })
    }

    func testLinksInsideCodeBlocksAndInlineCodeNeverChange() throws {
        let vault = try BrainVaultFixture()
        _ = try rename(vault, "recipes/apple-pie.md", "recipes/tart.md")
        let bread = try vault.text("recipes/bread.md")
        XCTAssertTrue(bread.contains("```\n[[apple-pie]] in code\n```"))
        XCTAssertTrue(bread.contains("`[[apple-pie]]`"))
    }

    func testMovingAFolderKeepsRelativeLinksValid() throws {
        let vault = try BrainVaultFixture()
        _ = try rename(vault, "projects", "work/projects")
        XCTAssertTrue(vault.exists("work/projects/garden.md"))
        XCTAssertEqual(try vault.text("work/projects/garden.md"), "# Garden\n\nPlant [[../../recipes/bread]] herbs. Also [[Tarte]].\n")
        XCTAssertEqual(try vault.text("index.md"), "# Home\n\nSee [[Apple Pie]] and [[projects/garden]].\n")
    }

    func testRenamingAnAttachmentRewritesItsEmbeds() throws {
        let vault = try BrainVaultFixture()
        let plan = try rename(vault, "photo.png", "images/pic.png")
        XCTAssertTrue(try vault.text("recipes/bread.md").contains("![[pic.png]]"))
        XCTAssertEqual(plan.linkCount, 1)
    }

    func testFrontmatterLinksAreUpdatedToo() throws {
        let vault = try BrainVaultFixture()
        try vault.put("related.md", "---\nsee: \"[[recipes/bread]]\"\n---\nbody\n")
        _ = try rename(vault, "recipes/bread.md", "recipes/loaf.md")
        XCTAssertEqual(try vault.text("related.md"), "---\nsee: \"[[recipes/loaf]]\"\n---\nbody\n")
    }

    func testAmbiguousNameFallsBackToThePath() throws {
        let vault = try BrainVaultFixture(["a/dup.md": "# one\n", "b/dup.md": "# two\n", "c/ref.md": "[[b/dup]] and [[a/dup]]\n"])
        _ = try rename(vault, "b/dup.md", "b/renamed.md")
        XCTAssertEqual(try vault.text("c/ref.md"), "[[b/renamed]] and [[a/dup]]\n")
    }

    func testPreviewCountsWithoutWriting() throws {
        let vault = try BrainVaultFixture()
        let plan = try BrainRefactor.plan(root: vault.path, scan: vault.scan(), from: "recipes/bread.md", to: "recipes/sourdough.md")
        XCTAssertEqual(plan.linkCount, 1)
        XCTAssertTrue(vault.exists("recipes/bread.md"))
        XCTAssertEqual(try vault.text("projects/garden.md"), "# Garden\n\nPlant [[../recipes/bread]] herbs. Also [[Tarte]].\n")
    }

    func testStalePlanIsRefusedAndNothingChanges() throws {
        let vault = try BrainVaultFixture()
        let plan = try BrainRefactor.plan(root: vault.path, scan: vault.scan(), from: "recipes/bread.md", to: "recipes/sourdough.md")
        try vault.put("projects/garden.md", "edited elsewhere [[../recipes/bread]]\n")
        XCTAssertThrowsError(try BrainRefactor.apply(plan, root: vault.path)) { XCTAssertEqual($0 as? BrainFilesError, .stale("projects/garden.md")) }
        XCTAssertTrue(vault.exists("recipes/bread.md"))
        XCTAssertEqual(try vault.text("projects/garden.md"), "edited elsewhere [[../recipes/bread]]\n")
    }

    func testFailureAfterTheMoveRestoresEverything() throws {
        let vault = try BrainVaultFixture()
        var plan = try BrainRefactor.plan(root: vault.path, scan: vault.scan(), from: "recipes/bread.md", to: "recipes/sourdough.md")
        plan.edits.append(BrainFileEdit(oldPath: "projects/notes.md", newPath: "missing-folder/notes.md", oldText: try vault.text("projects/notes.md"), newText: "x", count: 1))
        XCTAssertThrowsError(try BrainRefactor.apply(plan, root: vault.path))
        XCTAssertTrue(vault.exists("recipes/bread.md"))
        XCTAssertFalse(vault.exists("recipes/sourdough.md"))
        XCTAssertEqual(try vault.text("projects/garden.md"), "# Garden\n\nPlant [[../recipes/bread]] herbs. Also [[Tarte]].\n")
        XCTAssertEqual(try vault.text("projects/notes.md"), "# Notes\n\n[[Missing note]]\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: vault.root.appendingPathComponent("projects").path).filter { $0.contains("wisp-edit") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testRefusesAnExistingDestinationAndAFolderIntoItself() throws {
        let vault = try BrainVaultFixture()
        let scan = try vault.scan()
        XCTAssertThrowsError(try BrainRefactor.plan(root: vault.path, scan: scan, from: "recipes/bread.md", to: "recipes/apple-pie.md"))
        XCTAssertThrowsError(try BrainRefactor.plan(root: vault.path, scan: scan, from: "recipes", to: "recipes/inner"))
        XCTAssertThrowsError(try BrainRefactor.plan(root: vault.path, scan: scan, from: "recipes/bread.md", to: "../escape.md"))
    }

    func testDeleteGoesToTheTrashHandlerNeverAHardDelete() throws {
        let vault = try BrainVaultFixture()
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let files = BrainFiles(root: vault.path) { url in
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
        }
        try files.trash("recipes/bread.md")
        XCTAssertFalse(vault.exists("recipes/bread.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.appendingPathComponent("bread.md").path))
        XCTAssertThrowsError(try files.trash("recipes/bread.md"))
    }

    func testAtomicWriteReplacesTheFileAndLeavesNoTemporary() throws {
        let vault = try BrainVaultFixture()
        let files = BrainFiles(root: vault.path)
        try files.write("new text", to: "recipes/bread.md")
        XCTAssertEqual(try vault.text("recipes/bread.md"), "new text")
        let names = try FileManager.default.contentsOfDirectory(atPath: vault.root.appendingPathComponent("recipes").path)
        XCTAssertFalse(names.contains { $0.contains(".wisp-") })
        XCTAssertThrowsError(try files.write("x", to: "../out.md"))
        XCTAssertThrowsError(try files.createNote("recipes/bread.md"))
    }
}
