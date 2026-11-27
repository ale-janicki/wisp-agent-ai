import XCTest

@testable import WispCore

final class GitStatusTests: XCTestCase {
    private let normal = """
        # branch.oid 4f2a9c1d0e8b7a6f5e4d3c2b1a0f9e8d7c6b5a49
        # branch.head feat/local-acme-client-assistant
        # branch.upstream origin/feat/local-acme-client-assistant
        # branch.ab +1 -0
        1 .M N... 100644 100644 100644 aaa bbb app/a.swift
        2 R. N... 100644 100644 100644 aaa bbb R100 new.swift\told.swift
        u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.swift
        ? untracked.txt
        ! ignored.log
        """

    func testBranchHeaderNormal() {
        XCTAssertEqual(GitStatus.branchName(normal), "feat/local-acme-client-assistant")
    }

    func testBranchHeaderDetachedUsesShortSha() {
        let text = "# branch.oid 4f2a9c1d0e8b7a6f5e4d3c2b1a0f9e8d7c6b5a49\n# branch.head (detached)\n"
        XCTAssertEqual(GitStatus.branchName(text), "4f2a9c1")
    }

    func testBranchHeaderInitialKeepsName() {
        let text = "# branch.oid (initial)\n# branch.head main\n? a.txt\n"
        XCTAssertEqual(GitStatus.branchName(text), "main")
        XCTAssertEqual(GitStatus.changedCount(text), 1)
    }

    func testNoBranchHeaderIsNotARepo() {
        XCTAssertNil(GitStatus.parse(porcelain: "", shortstat: ""))
    }

    func testDirtyCountIncludesUntrackedAndSkipsIgnored() {
        XCTAssertEqual(GitStatus.changedCount(normal), 4)
    }

    func testCleanTreeIsNotDirty() {
        let status = GitStatus.parse(porcelain: "# branch.oid abc\n# branch.head main\n", shortstat: "")
        XCTAssertEqual(status, GitStatus(branch: "main"))
        XCTAssertEqual(status?.isDirty, false)
        XCTAssertEqual(status?.isDefaultBranch, true)
    }

    func testShortstatBoth() {
        let stat = GitStatus.parseShortstat(" 3 files changed, 42 insertions(+), 7 deletions(-)\n")
        XCTAssertEqual(stat.insertions, 42)
        XCTAssertEqual(stat.deletions, 7)
    }

    func testShortstatOnlyInsertions() {
        let stat = GitStatus.parseShortstat(" 1 file changed, 1 insertion(+)\n")
        XCTAssertEqual(stat.insertions, 1)
        XCTAssertEqual(stat.deletions, 0)
    }

    func testShortstatOnlyDeletions() {
        let stat = GitStatus.parseShortstat(" 2 files changed, 9 deletions(-)\n")
        XCTAssertEqual(stat.insertions, 0)
        XCTAssertEqual(stat.deletions, 9)
    }

    func testShortstatEmpty() {
        let stat = GitStatus.parseShortstat("")
        XCTAssertEqual(stat.insertions, 0)
        XCTAssertEqual(stat.deletions, 0)
    }

    func testParseCombines() {
        let status = GitStatus.parse(porcelain: normal, shortstat: " 3 files changed, 42 insertions(+), 7 deletions(-)")
        XCTAssertEqual(status, GitStatus(branch: "feat/local-acme-client-assistant", changedFiles: 4, insertions: 42, deletions: 7))
    }

    func testDirectoryLabelElidesMiddleUnderHome() {
        XCTAssertEqual(ContextChips.directoryLabel("/fixture-home/repos/pessoal/local-gateway", home: "/fixture-home"), "~/…/local-gateway")
    }

    func testDirectoryLabelShortPathsStayWhole() {
        XCTAssertEqual(ContextChips.directoryLabel("/fixture-home", home: "/fixture-home"), "~")
        XCTAssertEqual(ContextChips.directoryLabel("/fixture-home/repos", home: "/fixture-home"), "~/repos")
        XCTAssertEqual(ContextChips.directoryLabel("/", home: "/fixture-home"), "/")
    }

    func testDirectoryLabelOutsideHome() {
        XCTAssertEqual(ContextChips.directoryLabel("/usr/local/bin", home: "/fixture-home"), "/…/bin")
        XCTAssertEqual(ContextChips.directoryLabel("/usr/local", home: nil), "/usr/local")
    }

    private func block(_ id: Int, _ status: TerminalBlock.Status) -> TerminalBlock {
        TerminalBlock(
            id: id, command: "git checkout main", directory: nil, startedAt: Date(), finishedAt: nil, status: status, promptRow: 0,
            outputStart: 0, outputEnd: nil, headLines: 0)
    }

    func testLastFinishedIDIgnoresRunningAndChangesPerCommand() {
        XCTAssertNil(ContextChips.lastFinishedID([]))
        XCTAssertNil(ContextChips.lastFinishedID([block(1, .running)]))
        XCTAssertEqual(ContextChips.lastFinishedID([block(1, .finished(0)), block(2, .running)]), 1)
        XCTAssertEqual(ContextChips.lastFinishedID([block(1, .finished(0)), block(2, .finished(1))]), 2)
    }
}
