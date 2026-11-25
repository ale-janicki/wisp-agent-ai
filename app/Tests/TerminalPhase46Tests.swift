import AppKit
import Darwin
import WispCore
import XCTest

@testable import Wisp

@MainActor
class TerminalPaneCase: XCTestCase {
    var window: NSWindow!
    var pane: TerminalPaneView!
    var session: TerminalSession!
    var engine: SwiftTermEngine!

    override func setUp() async throws {
        let home = NSHomeDirectory()
        let shell = TerminalShell.resolve(shellVariable: "/bin/zsh")
        let integrationURL = try XCTUnwrap(
            Bundle.main.url(forResource: "ShellIntegration", withExtension: nil), "the app bundle has no ShellIntegration folder")
        let env = TerminalEnvironment.build(
            base: ProcessInfo.processInfo.environment, shell: shell, home: home, user: NSUserName(), version: "test")
        session = TerminalSession(
            shell: shell, environment: env, directory: home, integration: ShellIntegration(directory: integrationURL),
            integrationEnabled: { true }, nativeBlocks: { true }
        ) { SwiftTermEngine() }
        engine = try XCTUnwrap(session.engine as? SwiftTermEngine)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        pane.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(pane)
        window.backgroundColor = NSColor(Theme.bg)
        window.contentView?.wantsLayer = true
        window.orderBack(nil)
        pane.attach(engine: engine, session: session)
        render()
        session.start(size: TerminalSize(columns: 110, rows: 36))
        render()
    }

    override func tearDown() async throws {
        session?.close()
        window?.orderOut(nil)
    }

    func render() {
        window.contentView?.layoutSubtreeIfNeeded()
        pane.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        window.contentView?.display()
    }

    @discardableResult
    func pump(_ timeout: TimeInterval = 15, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            render()
            if condition() { return true }
        }
        render()
        return condition()
    }

    func pumpFor(_ seconds: TimeInterval) {
        var first = true
        let end = Date().addingTimeInterval(seconds)
        pump(seconds + 1) {
            defer { first = false }
            return Date() >= end && !first
        }
    }

    var blocks: [TerminalBlock] { session.blocks.blocks }

    func waitForPrompt() {
        XCTAssertTrue(pump { self.session.isRunning && !self.session.promptLines.isEmpty }, "the shell never showed a prompt")
    }

    func texts(_ block: TerminalBlock?) -> [String] { block?.output?.lines.map(\.text) ?? [] }

    @discardableResult
    func run(_ line: String, expecting count: Int, timeout: TimeInterval = 20, file: StaticString = #filePath, at sourceLine: UInt = #line) -> TerminalBlock? {
        XCTAssertTrue(session.submit(line), "submit refused: \(line)", file: file, line: sourceLine)
        let done = pump(timeout) { self.blocks.count == count && self.blocks.last?.isRunning == false && self.blocks.last?.output != nil }
        XCTAssertTrue(done, "block \(count) (\(line)) did not finish; blocks: \(blocks.map { "\($0.command) \($0.status)" })", file: file, line: sourceLine)
        return blocks.last
    }

    func key(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
        pane.editor.keyDown(with: try! XCTUnwrap(event))
        render()
    }

    func typeKeys(_ text: String) {
        for character in text { key(0, String(character)) }
    }

    func enter() { key(36, "\r") }

    @discardableResult
    func shortcut(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode)!
        let handled = window.performKeyEquivalent(with: event)
        render()
        return handled
    }

    var liveText: String { engine.liveOutput(from: 0).plainText }

    func scratchFile(_ name: String, contents: String = "x\n") throws -> String {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("wisp-phase46-\(getpid())")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = (directory as NSString).appendingPathComponent(name)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        return path
    }
}

@MainActor
final class TerminalPhase46Tests: TerminalPaneCase {
    func testShiftCommandGTogglesTheGridAndTheHintFades() throws {
        waitForPrompt()
        window.makeFirstResponder(pane.editor)
        XCTAssertEqual(session.mode, .blocks)
        XCTAssertTrue(shortcut(5, "G", [.command, .shift]), "⇧⌘G was not taken")
        XCTAssertEqual(session.mode, .grid(.manual))
        XCTAssertFalse(engine.view.isHidden)
        XCTAssertTrue(pane.list.isHidden)
        XCTAssertTrue(pane.isGridHintVisible, "the hint is on when the grid comes up")
        XCTAssertTrue(window.firstResponder === engine.view, "the grid has the keyboard")
        pumpFor(1)
        XCTAssertTrue(pane.isGridHintVisible, "still there after 1 s")
        XCTAssertTrue(pump(6) { !self.pane.isGridHintVisible }, "the hint never faded")
        XCTAssertTrue(shortcut(5, "G", [.command, .shift]))
        XCTAssertEqual(session.mode, .blocks)
        XCTAssertTrue(engine.view.isHidden)
        XCTAssertFalse(pane.list.isHidden)
        XCTAssertTrue(window.firstResponder === pane.editor)
        XCTAssertTrue(session.submit("sleep 1"))
        XCTAssertTrue(pump { self.session.isCommandRunning })
        shortcut(5, "G", [.command, .shift])
        XCTAssertEqual(session.mode, .grid(.manual))
        pumpFor(0.4)
        XCTAssertEqual(session.mode, .grid(.manual))
        XCTAssertTrue(pump { !self.session.isCommandRunning })
        XCTAssertEqual(session.mode, .blocks, "the end of the command gave the pane back")
        XCTAssertEqual(blocks.last?.output?.plainText, "")
    }

    func testReadReturnsWhatWasTypedAndTheEditorAsksForTheAnswer() throws {
        waitForPrompt()
        window.makeFirstResponder(pane.editor)
        XCTAssertTrue(session.submit("printf 'Name: '; read x; echo got:$x"))
        XCTAssertTrue(pump { self.session.isCommandRunning && self.pane.editor.forwardsKeys })
        XCTAssertTrue(
            pump { self.pane.editor.placeholder == "Digite a resposta para o programa" },
            "the placeholder is \"\(pane.editor.placeholder)\" (live: \(liveText.debugDescription))")
        XCTAssertEqual(session.mode, .blocks)
        typeKeys("abc")
        XCTAssertTrue(pump { self.liveText.contains("Name: abc") }, "the tty echo is missing: \(liveText.debugDescription)")
        enter()
        XCTAssertTrue(pump { self.blocks.count == 1 && self.blocks.last?.output != nil && self.blocks.last?.isRunning == false })
        XCTAssertTrue(texts(blocks.last).contains("got:abc"), "output: \(texts(blocks.last))")
        XCTAssertEqual(blocks.last?.status, .finished(0))
        XCTAssertEqual(pane.editor.placeholder, "Digite um comando (⇧↩ para nova linha)")
    }

    func testAPasswordPromptShowsNoEcho() throws {
        waitForPrompt()
        window.makeFirstResponder(pane.editor)
        XCTAssertTrue(session.submit("stty -echo; printf 'Password:'; read x; stty echo; echo; echo got:$x"))
        XCTAssertTrue(pump { self.pane.editor.placeholder == "Digite a resposta para o programa" })
        typeKeys("s3cret")
        pumpFor(0.5)
        XCTAssertFalse(liveText.contains("s3cret"), "a password was echoed: \(liveText.debugDescription)")
        XCTAssertTrue(liveText.contains("Password:"))
        enter()
        XCTAssertTrue(pump { self.blocks.count == 1 && self.blocks.last?.output != nil && self.blocks.last?.isRunning == false })
        XCTAssertTrue(texts(blocks.last).contains("got:s3cret"), "output: \(texts(blocks.last))")
        XCTAssertFalse(texts(blocks.last).contains { $0.contains("Password:s3cret") })
    }

    func testRemoveInteractiveTakesYAndEnter() throws {
        waitForPrompt()
        window.makeFirstResponder(pane.editor)
        let path = try scratchFile("victim.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(session.submit("rm -i \(path)"))
        XCTAssertTrue(pump { self.pane.editor.placeholder == "Digite a resposta para o programa" }, "live: \(liveText.debugDescription)")
        typeKeys("y")
        enter()
        XCTAssertTrue(pump { self.blocks.count == 1 && self.blocks.last?.output != nil && self.blocks.last?.isRunning == false })
        XCTAssertEqual(blocks.last?.status, .finished(0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "rm -i did not get the y")
    }

    func testControlDSendsEndOfTransmissionAndControlCSendsInterrupt() throws {
        waitForPrompt()
        window.makeFirstResponder(pane.editor)
        XCTAssertTrue(session.submit("cat"))
        XCTAssertTrue(pump { self.session.isCommandRunning && self.pane.editor.forwardsKeys })
        typeKeys("hi")
        enter()
        XCTAssertTrue(pump { self.liveText.contains("hi\nhi") || self.liveText.components(separatedBy: "hi").count >= 3 }, "live: \(liveText.debugDescription)")
        key(2, "d", [.control])
        XCTAssertTrue(pump { self.blocks.count == 1 && self.blocks.last?.output != nil && self.blocks.last?.isRunning == false })
        XCTAssertEqual(blocks.last?.status, .finished(0), "cat ends cleanly on EOT")

        XCTAssertTrue(session.submit("sleep 30"))
        XCTAssertTrue(pump { self.session.isCommandRunning })
        key(8, "c", [.control])
        XCTAssertTrue(pump(8) { self.blocks.count == 2 && self.blocks.last?.isRunning == false })
        XCTAssertEqual(blocks.last?.status, .finished(130), "⌃C interrupts the program: \(String(describing: blocks.last?.status))")
    }

    func testResizingTheWindowInTheGridReachesTheProgram() throws {
        waitForPrompt()
        window.makeFirstResponder(pane.editor)
        XCTAssertTrue(session.submit("vim -u NONE"))
        XCTAssertTrue(pump { self.session.mode == .grid(.alternateScreen) || self.session.mode == .grid(.allowlisted) })
        pumpFor(0.5)
        let before = engine.view.terminalDimensions
        window.setContentSize(NSSize(width: 640, height: 380))
        render()
        XCTAssertTrue(pump { self.engine.view.terminalDimensions.cols != before.cols }, "the grid kept \(before) after the resize")
        pumpFor(0.4)
        let after = engine.view.terminalDimensions
        XCTAssertLessThan(after.cols, before.cols)
        XCTAssertLessThan(after.rows, before.rows)
        session.write(Array(":q\r".utf8))
        XCTAssertTrue(pump { !self.session.isCommandRunning && self.blocks.last?.output != nil })
        let stty = run("stty size", expecting: 2)
        let reported = texts(stty).first { !$0.isEmpty } ?? ""
        XCTAssertEqual(reported, "\(after.rows) \(after.cols)", "the pty says \(reported), the grid \(after)")
    }

    func testCaptureKeepsStylesWideCharactersAndRowsAcrossChunks() throws {
        waitForPrompt()
        let styled = run("printf '\\033[31mred\\033[0m plain \\033[1;32mbold\\033[0m\\n日本x\\n'", expecting: 1)
        let lines = try XCTUnwrap(styled?.output?.lines)
        XCTAssertEqual(lines.map(\.text), ["red plain bold", "日本x"])
        XCTAssertEqual(lines[0].runs.map(\.range), [0..<3, 3..<10, 10..<14])
        XCTAssertEqual(lines[0].runs[0].style.fg, .ansi(1))
        XCTAssertEqual(lines[0].runs[1].style, .plain)
        XCTAssertEqual(lines[0].runs[2].style.fg, .ansi(2))
        XCTAssertTrue(lines[0].runs[2].style.bold)
        let many = run("seq 1 2500", expecting: 2)
        let numbers = texts(many)
        XCTAssertEqual(numbers.count, 2500)
        XCTAssertEqual(numbers.first, "1")
        XCTAssertEqual(numbers.last, "2500")
        XCTAssertEqual(numbers[1000], "1001", "the rows at a chunk's edge are not lost")
        XCTAssertEqual(many?.output?.droppedLines, 0)
    }

    func testClearEmptiesTheList() throws {
        waitForPrompt()
        run("echo one", expecting: 1)
        run("echo two", expecting: 2)
        XCTAssertTrue(session.submit("clear"))
        XCTAssertTrue(pump { self.blocks.isEmpty && !self.session.isCommandRunning }, "blocks: \(blocks.map(\.command))")
        XCTAssertEqual(pane.list.blockCount, 0)
        XCTAssertTrue(session.isRunning)
        run("echo three", expecting: 1)
        XCTAssertTrue(session.submit("tput clear"))
        XCTAssertTrue(pump { self.blocks.isEmpty && !self.session.isCommandRunning }, "blocks: \(blocks.map(\.command))")
    }

    #if DEBUG

    private func bodyViews(in view: NSView) -> [BlockOutputTextView] {
        var found = [BlockOutputTextView]()
        if let text = view as? BlockOutputTextView, !text.lines.isEmpty { found.append(text) }
        for child in view.subviews { found += bodyViews(in: child) }
        return found
    }

    private func color(of text: NSTextView, at index: Int = 0) -> NSColor? {
        text.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    func testChangingTheThemeRecolorsBlocksEditorAndMenuWithoutRestarting() throws {
        let settings = AppSettings.shared
        let saved = settings.settings
        let persisted = settings.persists
        settings.persists = false
        defer {
            settings.applyForSnapshot(saved)
            settings.persists = persisted
        }
        waitForPrompt()
        run("echo themed", expecting: 1)
        let shellPid = engine.view.process.shellPid
        let rows = bodyViews(in: pane.list)
        let row = try XCTUnwrap(rows.first { $0.lines.map(\.text).contains("themed") }, "no block row shows the output")
        let darkText = try XCTUnwrap(color(of: row))
        let editorBefore = try XCTUnwrap(pane.editor.textColor)
        let fontBefore = try XCTUnwrap(row.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize

        settings.setCustom(\.background, to: HexColor(0xFFFFFF))
        settings.setCustom(\.surface, to: HexColor(0xEEEEEE))
        XCTAssertTrue(pump(5) { (self.bodyViews(in: self.pane.list).first.flatMap { self.color(of: $0) }).map { $0 != darkText } ?? false },
                      "the block's text colour did not change")
        let lightText = try XCTUnwrap(bodyViews(in: pane.list).first.flatMap { color(of: $0) })
        XCTAssertEqual(lightText, TerminalTheme.ns(settings.colors.textPrimary))
        XCTAssertNotEqual(pane.editor.textColor, editorBefore)
        XCTAssertEqual(pane.editor.textColor, TerminalTheme.ns(settings.colors.textPrimary))

        engine.applyTheme(settings.colors, fontSize: 17)
        pane.attach(engine: engine, session: session)
        render()
        let fontAfter = try XCTUnwrap(bodyViews(in: pane.list).first?.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertNotEqual(fontAfter.pointSize, fontBefore)
        XCTAssertEqual(fontAfter.pointSize, 17)
        XCTAssertEqual(pane.editor.font?.pointSize, 17)

        XCTAssertEqual(engine.view.process.shellPid, shellPid, "the shell was not restarted")
        XCTAssertTrue(session.isRunning)
        run("echo after", expecting: 2)
    }
    #endif
}
