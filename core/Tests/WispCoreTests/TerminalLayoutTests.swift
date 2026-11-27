import CoreGraphics
import XCTest
@testable import WispCore

final class TerminalLayoutTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    private func threePanes() -> TerminalLayout {
        var layout = TerminalLayout()
        layout.addTab(session: a)
        layout.split(.horizontal, adding: b)
        layout.split(.vertical, adding: c)
        return layout
    }

    private func twoPanes() -> TerminalLayout {
        var layout = TerminalLayout()
        layout.addTab(session: a)
        layout.split(.horizontal, adding: b)
        return layout
    }

    func testMoveOnEachEdgeOfTwoPanes() throws {
        let cases: [(TerminalLayout.DropEdge, TerminalLayout.Node)] = [
            (.left, .split(.horizontal, ratio: 0.5, first: .leaf(b), second: .leaf(a))),
            (.right, .split(.horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))),
            (.top, .split(.vertical, ratio: 0.5, first: .leaf(b), second: .leaf(a))),
            (.bottom, .split(.vertical, ratio: 0.5, first: .leaf(a), second: .leaf(b))),
        ]
        for (edge, expected) in cases {
            var layout = twoPanes()
            XCTAssertTrue(layout.move(b, onto: a, edge: edge))
            XCTAssertEqual(layout.selectedTab?.root, expected, "\(edge)")
            XCTAssertEqual(layout.focusedSession, b)
        }
    }

    func testMoveOnEachEdgeOfThreePanes() throws {
        var layout = threePanes()
        XCTAssertTrue(layout.move(c, onto: a, edge: .top))
        XCTAssertEqual(layout.selectedTab?.root, .split(.horizontal, ratio: 0.5,
            first: .split(.vertical, ratio: 0.5, first: .leaf(c), second: .leaf(a)), second: .leaf(b)))

        layout = threePanes()
        XCTAssertTrue(layout.move(a, onto: c, edge: .left))
        XCTAssertEqual(layout.selectedTab?.root, .split(.vertical, ratio: 0.5,
            first: .leaf(b), second: .split(.horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(c))))

        layout = threePanes()
        XCTAssertTrue(layout.move(a, onto: b, edge: .bottom))
        XCTAssertEqual(layout.selectedTab?.root, .split(.vertical, ratio: 0.5,
            first: .split(.vertical, ratio: 0.5, first: .leaf(b), second: .leaf(a)), second: .leaf(c)))

        layout = threePanes()
        XCTAssertTrue(layout.move(b, onto: c, edge: .right))
        XCTAssertEqual(layout.selectedTab?.root, .split(.horizontal, ratio: 0.5,
            first: .leaf(a), second: .split(.horizontal, ratio: 0.5, first: .leaf(c), second: .leaf(b))))
        XCTAssertEqual(layout.selectedTab?.sessions.sorted { $0.uuidString < $1.uuidString }, [a, b, c].sorted { $0.uuidString < $1.uuidString })
    }

    func testMoveCenterSwapsLeavesKeepingRatios() throws {
        var layout = threePanes()
        layout.resize([], to: 0.3)
        XCTAssertTrue(layout.move(a, onto: c, edge: .center))
        XCTAssertEqual(layout.selectedTab?.root, .split(.horizontal, ratio: 0.3,
            first: .leaf(c), second: .split(.vertical, ratio: 0.5, first: .leaf(b), second: .leaf(a))))
        XCTAssertEqual(layout.focusedSession, a)
    }

    func testMoveRefusesSelfUnknownAndOtherTabSessions() {
        var layout = twoPanes()
        layout.addTab(session: c)
        layout.selectTab(at: 0)
        let before = layout
        XCTAssertFalse(layout.move(a, onto: a, edge: .left))
        XCTAssertFalse(layout.move(c, onto: a, edge: .left))
        XCTAssertFalse(layout.move(a, onto: c, edge: .center))
        XCTAssertFalse(layout.move(d, onto: a, edge: .right))
        XCTAssertEqual(layout, before)
    }

    func testDropTargetPicksNearestEdgeOrCentre() {
        let frames = twoPanes().selectedTab?.frames ?? [:]
        XCTAssertNil(TerminalLayout.dropTarget(at: CGPoint(x: 0.25, y: 0.5), in: frames, excluding: a))
        XCTAssertEqual(TerminalLayout.dropTarget(at: CGPoint(x: 0.75, y: 0.5), in: frames, excluding: a)?.edge, .center)
        XCTAssertEqual(TerminalLayout.dropTarget(at: CGPoint(x: 0.55, y: 0.5), in: frames, excluding: a)?.edge, .left)
        XCTAssertEqual(TerminalLayout.dropTarget(at: CGPoint(x: 0.95, y: 0.5), in: frames, excluding: a)?.edge, .right)
        XCTAssertEqual(TerminalLayout.dropTarget(at: CGPoint(x: 0.75, y: 0.05), in: frames, excluding: a)?.edge, .top)
        XCTAssertEqual(TerminalLayout.dropTarget(at: CGPoint(x: 0.75, y: 0.95), in: frames, excluding: a)?.edge, .bottom)
        XCTAssertNil(TerminalLayout.dropTarget(at: CGPoint(x: 2, y: 2), in: frames, excluding: a))
    }

    func testAddTabSelectsItAndFocusesItsPane() {
        var layout = TerminalLayout()
        layout.addTab(session: a)
        layout.addTab(session: b)
        XCTAssertEqual(layout.tabs.count, 2)
        XCTAssertEqual(layout.selectedIndex, 1)
        XCTAssertEqual(layout.focusedSession, b)
    }

    func testSplitHalvesTheFocusedPaneAndFocusesTheNewOne() throws {
        let layout = threePanes()
        let tab = try XCTUnwrap(layout.selectedTab)
        XCTAssertEqual(tab.root, .split(.horizontal, ratio: 0.5, first: .leaf(a), second: .split(.vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))))
        XCTAssertEqual(tab.focused, c)
        XCTAssertEqual(tab.sessions, [a, b, c])
        XCTAssertEqual(tab.frames[a], CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(tab.frames[b], CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(tab.frames[c], CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    func testSplitRefusesASessionAlreadyLaidOutOrNoTab() {
        var empty = TerminalLayout()
        XCTAssertFalse(empty.split(.horizontal, adding: a))
        var layout = threePanes()
        let before = layout
        XCTAssertFalse(layout.split(.horizontal, adding: b))
        XCTAssertEqual(layout, before)
    }

    func testClosingAPaneCollapsesItsSplitAndFocusesTheSibling() throws {
        var layout = threePanes()
        XCTAssertEqual(layout.close(c), .pane)
        let tab = try XCTUnwrap(layout.selectedTab)
        XCTAssertEqual(tab.root, .split(.horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b)))
        XCTAssertEqual(tab.focused, b)
        XCTAssertEqual(tab.frames[b], CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
    }

    func testClosingTheFirstChildHandsFocusToTheNearestPaneOfTheSibling() throws {
        var layout = threePanes()
        layout.focus(a)
        XCTAssertEqual(layout.close(a), .pane)
        let tab = try XCTUnwrap(layout.selectedTab)
        XCTAssertEqual(tab.root, .split(.vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c)))
        XCTAssertEqual(tab.focused, b)
    }

    func testClosingAnUnfocusedPaneKeepsTheFocus() {
        var layout = threePanes()
        layout.close(a)
        XCTAssertEqual(layout.focusedSession, c)
    }

    func testClosingTheLastPaneClosesTheTabAndSelectsANeighbour() {
        var layout = TerminalLayout()
        layout.addTab(session: a)
        layout.addTab(session: b)
        layout.addTab(session: c)
        layout.selectTab(at: 1)
        XCTAssertEqual(layout.close(b), .tab)
        XCTAssertEqual(layout.tabs.map(\.sessions), [[a], [c]])
        XCTAssertEqual(layout.focusedSession, c)
        XCTAssertEqual(layout.close(c), .tab)
        XCTAssertEqual(layout.focusedSession, a)
        XCTAssertEqual(layout.close(a), .tab)
        XCTAssertTrue(layout.tabs.isEmpty)
        XCTAssertNil(layout.selectedTabID)
        XCTAssertNil(layout.close(a), "a session no tab holds is nothing to close")
    }

    func testClosingAPaneOfAnotherTabKeepsTheSelection() {
        var layout = threePanes()
        layout.addTab(session: d)
        XCTAssertEqual(layout.close(b), .pane)
        XCTAssertEqual(layout.focusedSession, d)
        XCTAssertEqual(layout.tabs[0].focused, c)
    }

    func testFocusByDirectionInANestedTree() {
        var layout = threePanes()
        XCTAssertTrue(layout.moveFocus(.up))
        XCTAssertEqual(layout.focusedSession, b)
        XCTAssertFalse(layout.moveFocus(.up), "nothing above the top")
        XCTAssertFalse(layout.moveFocus(.right), "nothing right of the right edge")
        XCTAssertTrue(layout.moveFocus(.left))
        XCTAssertEqual(layout.focusedSession, a)
        XCTAssertTrue(layout.moveFocus(.right))
        XCTAssertEqual(layout.focusedSession, c, "b and c both touch a; the middle of a is the top edge of c")
        XCTAssertFalse(layout.moveFocus(.down))
        XCTAssertTrue(layout.moveFocus(.up))
        XCTAssertEqual(layout.focusedSession, b)
    }

    func testFocusRightPrefersThePaneInLineWithTheMiddle() {
        var layout = TerminalLayout()
        layout.addTab(session: a)
        layout.split(.horizontal, adding: b)
        layout.split(.vertical, adding: c)
        layout.resize([1], to: 0.7)
        layout.focus(a)
        layout.moveFocus(.right)
        XCTAssertEqual(layout.focusedSession, b, "the middle of a is in b once b is the taller one")
    }

    func testFocusSkipsPanesThatShareNoEdge() {
        var layout = TerminalLayout()
        layout.addTab(session: a)
        layout.split(.horizontal, adding: c)
        layout.split(.vertical, adding: d)
        layout.resize([1], to: 0.8)
        layout.focus(a)
        layout.split(.vertical, adding: b)
        layout.resize([0], to: 0.2)
        layout.focus(b)
        layout.moveFocus(.right)
        XCTAssertEqual(layout.focusedSession, c, "b (0.2…1) meets c (0…0.8) and d (0.8…1); the middle 0.6 is in c")
        layout.focus(d)
        layout.moveFocus(.left)
        XCTAssertEqual(layout.focusedSession, b, "a (0…0.2) does not reach d (0.8…1)")
    }

    func testNeighbourOfAnUnknownPaneIsNil() {
        XCTAssertNil(TerminalLayout.neighbour(of: a, toward: .left, in: [b: CGRect(x: 0, y: 0, width: 1, height: 1)]))
    }

    func testResizeClampsTheRatioAndReachesNestedSplits() throws {
        var layout = threePanes()
        layout.resize([], to: 0.05)
        layout.resize([1], to: 0.99)
        let tab = try XCTUnwrap(layout.selectedTab)
        XCTAssertEqual(tab.root, .split(.horizontal, ratio: 0.15, first: .leaf(a), second: .split(.vertical, ratio: 0.85, first: .leaf(b), second: .leaf(c))))
        layout.resize([0], to: 0.5)
        layout.resize([], to: .nan)
        XCTAssertEqual(layout.selectedTab, tab, "a path to a leaf or a ratio that is no number changes nothing")
    }

    func testDividersNameTheirSplitAndTurnAPointIntoARatio() throws {
        let tab = try XCTUnwrap(threePanes().selectedTab)
        let dividers = tab.dividers
        XCTAssertEqual(dividers.map(\.path), [[], [1]])
        XCTAssertEqual(dividers[1].bounds, CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(dividers[0].ratio(at: CGPoint(x: 0.25, y: 0.9)), 0.25, accuracy: 1e-9)
        XCTAssertEqual(dividers[1].ratio(at: CGPoint(x: 0.1, y: 0.75)), 0.75, accuracy: 1e-9)
    }

    func testMaximizeShowsOnlyTheFocusedPaneAndEndsOnAnyLayoutChange() throws {
        var single = TerminalLayout()
        single.addTab(session: a)
        XCTAssertFalse(single.toggleMaximize(), "one pane has nothing to maximize")

        var layout = threePanes()
        XCTAssertTrue(layout.toggleMaximize())
        var tab = try XCTUnwrap(layout.selectedTab)
        XCTAssertEqual(tab.frames, [c: CGRect(x: 0, y: 0, width: 1, height: 1)])
        XCTAssertTrue(tab.dividers.isEmpty)
        XCTAssertFalse(layout.moveFocus(.up), "focus does not move to a pane out of sight")
        XCTAssertTrue(layout.toggleMaximize())
        tab = try XCTUnwrap(layout.selectedTab)
        XCTAssertEqual(tab.frames.count, 3)

        layout.toggleMaximize()
        layout.split(.horizontal, adding: d)
        XCTAssertEqual(try XCTUnwrap(layout.selectedTab).maximized, false)
        layout.toggleMaximize()
        layout.close(d)
        XCTAssertEqual(try XCTUnwrap(layout.selectedTab).maximized, false)
    }

    func testTabIndexShortcutsBeyondTheCountAreNoOps() {
        var layout = TerminalLayout()
        layout.addTab(session: a)
        layout.addTab(session: b)
        XCTAssertTrue(layout.selectTab(at: 0))
        XCTAssertEqual(layout.focusedSession, a)
        XCTAssertFalse(layout.selectTab(at: 2))
        XCTAssertFalse(layout.selectTab(at: 8))
        XCTAssertFalse(layout.selectTab(at: -1))
        XCTAssertEqual(layout.focusedSession, a)
        XCTAssertFalse(layout.selectTab(UUID()))
    }

    func testAdjacentTabWrapsRoundTheEnds() {
        var layout = TerminalLayout()
        layout.addTab(session: a)
        XCTAssertFalse(layout.selectAdjacentTab(1), "one tab has no neighbour")
        layout.addTab(session: b)
        layout.addTab(session: c)
        layout.selectAdjacentTab(1)
        XCTAssertEqual(layout.focusedSession, a)
        layout.selectAdjacentTab(-1)
        XCTAssertEqual(layout.focusedSession, c)
        layout.selectAdjacentTab(-1)
        XCTAssertEqual(layout.focusedSession, b)
    }

    func testCommandNineSelectsTheLastTab() {
        var layout = TerminalLayout()
        XCTAssertFalse(layout.selectLastTab())
        for id in [a, b, c] { layout.addTab(session: id) }
        layout.selectTab(at: 0)
        XCTAssertTrue(layout.selectLastTab())
        XCTAssertEqual(layout.focusedSession, c)
    }

    func testMoveSelectedTabStopsAtTheEnds() {
        var layout = TerminalLayout()
        for id in [a, b, c] { layout.addTab(session: id) }
        layout.selectTab(at: 0)
        XCTAssertFalse(layout.moveSelectedTab(-1))
        XCTAssertTrue(layout.moveSelectedTab(1))
        XCTAssertEqual(layout.tabs.map(\.focused), [b, a, c])
        XCTAssertEqual(layout.selectedIndex, 1)
        XCTAssertTrue(layout.moveSelectedTab(1))
        XCTAssertFalse(layout.moveSelectedTab(1))
        XCTAssertEqual(layout.tabs.map(\.focused), [b, c, a])
    }

    func testPreviousAndNextPaneGoInReadingOrderRoundTheEnds() {
        var layout = threePanes()
        XCTAssertTrue(layout.focusAdjacentPane(1))
        XCTAssertEqual(layout.focusedSession, a)
        XCTAssertTrue(layout.focusAdjacentPane(-1))
        XCTAssertEqual(layout.focusedSession, c)
        layout.focusAdjacentPane(-1)
        XCTAssertEqual(layout.focusedSession, b)
        var single = TerminalLayout()
        single.addTab(session: d)
        XCTAssertFalse(single.focusAdjacentPane(1))
    }

    func testResizeFocusedMovesTheNearestDividerOfThatAxis() throws {
        var layout = threePanes()
        XCTAssertTrue(layout.resizeFocused(.up))
        XCTAssertTrue(layout.resizeFocused(.left))
        var tab = try XCTUnwrap(layout.selectedTab)
        XCTAssertEqual(tab.dividers[0].ratio, 0.45, accuracy: 1e-9, "c sits in the right half: left moves the root divider")
        XCTAssertEqual(tab.dividers[1].ratio, 0.45, accuracy: 1e-9, "the b/c split is the nearest vertical one")
        layout.focus(a)
        for _ in 0..<20 { layout.resizeFocused(.right) }
        XCTAssertFalse(layout.resizeFocused(.down), "a has no vertical split around it")
        tab = try XCTUnwrap(layout.selectedTab)
        XCTAssertEqual(tab.dividers[0].ratio, 0.85, accuracy: 1e-9)
    }

    func testInsertTabPutsItBackAndRemapsItsPanes() throws {
        var layout = threePanes()
        let closed = try XCTUnwrap(layout.selectedTab)
        layout.addTab(session: d)
        layout.closeTab(closed.id)
        let x = UUID(), y = UUID(), z = UUID()
        layout.insertTab(closed.remapped([a: x, b: y, c: z]), at: 0)
        XCTAssertEqual(layout.tabs.map(\.sessions), [[x, y, z], [d]])
        XCTAssertEqual(layout.focusedSession, z)
        XCTAssertEqual(layout.selectedTab?.root, .split(.horizontal, ratio: 0.5, first: .leaf(x), second: .split(.vertical, ratio: 0.5, first: .leaf(y), second: .leaf(z))))
    }

    func testFocusSelectsThePanesTab() {
        var layout = threePanes()
        layout.addTab(session: d)
        XCTAssertTrue(layout.focus(a))
        XCTAssertEqual(layout.selectedIndex, 0)
        XCTAssertEqual(layout.focusedSession, a)
        XCTAssertFalse(layout.focus(UUID()))
    }

    func testMoveTabKeepsTheSelection() {
        var layout = TerminalLayout()
        layout.addTab(session: a)
        layout.addTab(session: b)
        layout.addTab(session: c)
        layout.moveTab(from: 2, to: 0)
        XCTAssertEqual(layout.tabs.map(\.focused), [c, a, b])
        XCTAssertEqual(layout.focusedSession, c)
        layout.moveTab(from: 0, to: 5)
        XCTAssertEqual(layout.tabs.map(\.focused), [c, a, b], "a destination past the end moves nothing")
    }

    func testRenameTrimsAndABlankNameRestoresTheAutomaticTitle() throws {
        var layout = TerminalLayout()
        layout.addTab(session: a)
        let id = try XCTUnwrap(layout.selectedTabID)
        layout.rename(id, to: "  api  ")
        XCTAssertEqual(layout.selectedTab?.customTitle, "api")
        layout.rename(id, to: "   ")
        XCTAssertNil(layout.selectedTab?.customTitle)
    }

    func testCloseTabHandsBackItsSessions() {
        var layout = threePanes()
        layout.addTab(session: d)
        let first = layout.tabs[0].id
        XCTAssertEqual(layout.closeTab(first), [a, b, c])
        XCTAssertEqual(layout.tabs.map(\.sessions), [[d]])
        XCTAssertEqual(layout.closeTab(first), [])
    }

    func testSearchMatchesEveryWordInTitleOrFolder() {
        let fields = ["git", "~/repos/Wisp Térm"]
        XCTAssertTrue(TerminalLayout.matches("", fields: fields))
        XCTAssertTrue(TerminalLayout.matches("  ", fields: fields))
        XCTAssertTrue(TerminalLayout.matches("GIT", fields: fields))
        XCTAssertTrue(TerminalLayout.matches("wisp term", fields: fields), "case and accents aside, words in any field")
        XCTAssertTrue(TerminalLayout.matches("git repos", fields: fields))
        XCTAssertFalse(TerminalLayout.matches("git docker", fields: fields))
    }
}

final class TerminalTabTitleTests: XCTestCase {
    func testCustomThenCommandThenFallback() {
        XCTAssertEqual(TerminalTabTitle.make(custom: "api", command: "npm run dev", fallback: "repo"), "api")
        XCTAssertEqual(TerminalTabTitle.make(custom: nil, command: "npm run dev", fallback: "repo"), "npm")
        XCTAssertEqual(TerminalTabTitle.make(custom: "", command: nil, fallback: "repo"), "repo")
        XCTAssertEqual(TerminalTabTitle.make(custom: nil, command: "  ", fallback: "repo"), "repo")
    }

    func testCommandNameSkipsAssignmentsAndWrappers() {
        XCTAssertEqual(TerminalTabTitle.commandName("FOO=1 sudo /usr/bin/git log"), "git")
        XCTAssertEqual(TerminalTabTitle.commandName("./scripts/build.sh --fast"), "build.sh")
        XCTAssertEqual(TerminalTabTitle.commandName("claude\nls"), "claude")
        XCTAssertNil(TerminalTabTitle.commandName("A=1 B=2"))
    }

    func testAbbreviatedFolder() {
        XCTAssertEqual(TerminalDirectory.abbreviated("/Users/dev", home: "/Users/dev"), "~")
        XCTAssertEqual(TerminalDirectory.abbreviated("/Users/dev/repos/x", home: "/Users/dev"), "~/repos/x")
        XCTAssertEqual(TerminalDirectory.abbreviated("/home/anabel", home: "/home/ana"), "/home/anabel")
        XCTAssertEqual(TerminalDirectory.abbreviated("/tmp", home: nil), "/tmp")
    }
}

final class TerminalActivityTests: XCTestCase {
    private func tracker(_ events: [(ShellEvent, Int)]) -> BlockTracker {
        var tracker = BlockTracker()
        for (event, row) in events { tracker.apply(event, anchor: BlockAnchor(row: row, column: 0)) }
        return tracker
    }

    func testRunningThenTheExitCodeDecidesTheBadge() {
        XCTAssertEqual(BlockTracker().activity, .idle)
        var events: [(ShellEvent, Int)] = [(.promptStart, 1), (.command("make test"), 1), (.commandStart, 2)]
        XCTAssertEqual(tracker(events).activity, TerminalActivity(state: .running, command: "make test"))
        events.append((.commandEnd(exitCode: 0), 5))
        XCTAssertEqual(tracker(events).activity, TerminalActivity(state: .succeeded, command: "make test"))
        let failed = [(ShellEvent.promptStart, 1), (.command("false"), 1), (.commandStart, 2), (.commandEnd(exitCode: 1), 2)]
        XCTAssertEqual(tracker(failed).activity, TerminalActivity(state: .failed(1), command: "false"))
        let lost = [(ShellEvent.promptStart, 1), (.command("sleep 9"), 1), (.commandStart, 2), (.commandEnd(exitCode: nil), 2)]
        XCTAssertEqual(tracker(lost).activity, TerminalActivity(state: .idle, command: "sleep 9"), "no code is no badge")
    }
}

@MainActor
final class TerminalSessionActivityTests: XCTestCase {
    private var engines = [FakeTerminalEngine]()

    private func stamp(_ event: ShellEvent, row: Int) -> StampedShellEvent {
        StampedShellEvent(event: event, anchor: BlockAnchor(row: row, column: 0), date: Date())
    }

    func testTheSessionPublishesItsActivityFromTheTrackerAndResetsOnReopen() {
        let session = TerminalSession(shell: TerminalShell(path: "/bin/zsh"), environment: ["HOME": "/home/dev"], directory: "/home/dev") { [unowned self] in
            let engine = FakeTerminalEngine()
            engines.append(engine)
            return engine
        }
        session.start()
        XCTAssertEqual(session.activity, .idle)
        engines[0].onShellEvents?([stamp(.promptStart, row: 0), stamp(.command("npm test"), row: 0), stamp(.commandStart, row: 1)])
        XCTAssertEqual(session.activity, TerminalActivity(state: .running, command: "npm test"))
        engines[0].onShellEvents?([stamp(.commandEnd(exitCode: 2), row: 4)])
        XCTAssertEqual(session.activity, TerminalActivity(state: .failed(2), command: "npm test"))
        engines[0].onExit?(0)
        session.reopen()
        XCTAssertEqual(session.activity, .idle, "a fresh shell starts with no badge")
        XCTAssertEqual(session.home, "/home/dev")
    }
}

final class TerminalShortcutKeyTests: XCTestCase {
    func testBracketsAreReadFromTheCharacterOnAnyLayout() {
        XCTAssertEqual(TerminalShortcutKey.bracket(characters: "[", keyCode: 0), -1)
        XCTAssertEqual(TerminalShortcutKey.bracket(characters: "}", keyCode: 0), 1)
        XCTAssertEqual(TerminalShortcutKey.bracket(characters: "{", keyCode: 99), -1)
        XCTAssertNil(TerminalShortcutKey.bracket(characters: "´", keyCode: TerminalShortcutKey.leftBracketCode), "ABNT2: the US [ key types an accent")
        XCTAssertNil(TerminalShortcutKey.bracket(characters: "a", keyCode: TerminalShortcutKey.rightBracketCode))
    }

    func testTheKeyCodeIsOnlyAFallbackWithoutCharacters() {
        XCTAssertEqual(TerminalShortcutKey.bracket(characters: nil, keyCode: TerminalShortcutKey.leftBracketCode), -1)
        XCTAssertEqual(TerminalShortcutKey.bracket(characters: "", keyCode: TerminalShortcutKey.rightBracketCode), 1)
        XCTAssertNil(TerminalShortcutKey.bracket(characters: "", keyCode: 0))
    }
}

@MainActor
final class TerminalOpenSessionDirectoryTests: XCTestCase {
    func testNewTabReadsWhereTheFocusedShellIsNow() {
        var engines = [FakeTerminalEngine]()
        var directories = [String]()
        let memory = TerminalDirectory.Memory(load: { nil }, save: { _ in }, isDirectory: { _ in true })
        let workspace = TerminalWorkspace(memory: memory, home: "/home/dev") { directory in
            directories.append(directory)
            return TerminalSession(shell: TerminalShell(path: "/bin/zsh"), environment: ["HOME": "/home/dev"], directory: directory) {
                let engine = FakeTerminalEngine()
                engines.append(engine)
                return engine
            }
        }
        workspace.openFirstIfNeeded()
        engines[0].liveDirectory = "/home/dev/live"
        workspace.openSession()
        XCTAssertEqual(directories, ["/home/dev", "/home/dev/live"])
    }
}
