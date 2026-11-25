import AppKit
import SwiftUI
import WispCore
import XCTest

@testable import Wisp

@MainActor
final class TerminalPaneSmokeTests: XCTestCase {
    private static let snapshot = "/private/tmp/claude-501/-Users-alejanicki/dc2e7dd4-de3c-4a89-8106-2f367e267ede/scratchpad/smoke/pane.png"

    private var window: NSWindow!
    private var pane: TerminalPaneView!
    private var session: TerminalSession!
    private var engine: SwiftTermEngine!

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
        session.measureHead = { [weak session] range in
            guard let engine = session?.engine as? SwiftTermEngine else { return 1 }
            return BlockText.lineCount(engine.rows(range))
        }
        engine = try XCTUnwrap(session.engine as? SwiftTermEngine)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        pane.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(pane)
        window.backgroundColor = NSColor(Theme.bg)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor(Theme.bg).cgColor
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

    private func render() {
        window.contentView?.layoutSubtreeIfNeeded()
        pane.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        window.contentView?.display()
    }

    @discardableResult
    private func pump(_ timeout: TimeInterval = 15, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            render()
            if condition() { return true }
        }
        render()
        return condition()
    }

    private func pumpFor(_ seconds: TimeInterval) {
        var first = true
        let end = Date().addingTimeInterval(seconds)
        pump(seconds + 1) {
            defer { first = false }
            return Date() >= end && !first
        }
    }

    private var blocks: [TerminalBlock] { session.blocks.blocks }

    private func waitForPrompt() {
        XCTAssertTrue(pump { self.session.isRunning && !self.session.promptLines.isEmpty }, "the shell never showed a prompt")
    }

    @discardableResult
    private func run(_ line: String, expecting count: Int, file: StaticString = #filePath, line sourceLine: UInt = #line) -> TerminalBlock? {
        XCTAssertTrue(session.submit(line), "submit refused: \(line)", file: file, line: sourceLine)
        let done = pump {
            self.blocks.count == count && self.blocks.last?.isRunning == false && self.blocks.last?.output != nil
        }
        XCTAssertTrue(done, "block \(count) (\(line)) did not finish; blocks: \(blocks.map { "\($0.command) \($0.status)" })", file: file, line: sourceLine)
        return blocks.last
    }

    private func texts(_ block: TerminalBlock?) -> [String] { block?.output?.lines.map(\.text) ?? [] }

    func testPaneDrivesCommandsWithoutCrashing() throws {
        XCTAssertTrue(session.isNative, "native blocks are not on for this shell")
        waitForPrompt()
        XCTAssertFalse(session.mode.isGrid, "the pane starts in blocks mode")

        let cd = run("cd ~/repos", expecting: 1)
        XCTAssertEqual(cd?.status, .finished(0))

        let ls = run("ls -G", expecting: 2)
        XCTAssertEqual(ls?.status, .finished(0))
        XCTAssertFalse(texts(ls).filter { !$0.isEmpty }.isEmpty, "ls printed nothing")

        let bad = run("ls /nope", expecting: 3)
        guard case .finished(let code) = bad?.status else { return XCTFail("ls /nope status: \(String(describing: bad?.status))") }
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(texts(bad).contains { $0.contains("/nope") }, "the error text is missing: \(texts(bad))")

        let printf = run("printf 'a\\nb\\nc\\n'", expecting: 4)
        XCTAssertEqual(printf?.status, .finished(0))
        XCTAssertEqual(texts(printf).filter { !$0.isEmpty }, ["a", "b", "c"])

        XCTAssertTrue(session.submit("echo \"abc"))
        pumpFor(0.6)
        XCTAssertEqual(blocks.count, 4, "an open quote must not start a block")
        XCTAssertTrue(session.submit("def\""), "the continuation line was refused")
        let done = pump { self.blocks.count == 5 && self.blocks.last?.isRunning == false && self.blocks.last?.output != nil }
        XCTAssertTrue(done, "the PS2 command did not finish: \(blocks.map { "\($0.command) \($0.status)" })")
        XCTAssertEqual(blocks.last?.status, .finished(0))
        XCTAssertEqual(texts(blocks.last).filter { !$0.isEmpty }, ["abc", "def"])

        XCTAssertTrue(session.submit("sleep 1"))
        XCTAssertTrue(pump { self.session.isCommandRunning }, "sleep never started")
        var ticks = 0
        let sleepEnd = Date().addingTimeInterval(1.2)
        while session.isCommandRunning, Date() < sleepEnd {
            pane.refreshLive()
            ticks += 1
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            render()
        }
        XCTAssertGreaterThan(ticks, 3, "the live tick did not run while the command was running")
        XCTAssertTrue(pump { self.blocks.count == 6 && self.blocks.last?.isRunning == false && self.blocks.last?.output != nil })
        XCTAssertEqual(blocks.last?.status, .finished(0))

        XCTAssertTrue(session.submit("for i in 1 2 3; do echo tick$i; sleep 0.3; done"))
        XCTAssertTrue(pump { self.session.isCommandRunning })
        while session.isCommandRunning {
            pane.refreshLive()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            render()
        }
        XCTAssertTrue(pump { self.blocks.count == 7 && self.blocks.last?.output != nil })
        XCTAssertEqual(texts(blocks.last).filter { !$0.isEmpty }, ["tick1", "tick2", "tick3"])

        XCTAssertTrue(session.submit("vim -u NONE"))
        XCTAssertTrue(pump { self.session.mode.isGrid }, "vim did not switch the pane to the grid")
        XCTAssertFalse(engine.view.isHidden, "the grid is hidden while vim runs")
        pumpFor(0.8)
        for key in [TerminalKey.text(":"), .text("q"), .enter] { session.sendKeys(key) }
        XCTAssertTrue(pump { !self.session.mode.isGrid }, "the pane did not come back to blocks after :q")
        XCTAssertTrue(pump { self.blocks.count == 8 && self.blocks.last?.isRunning == false })
        XCTAssertTrue(engine.view.isHidden, "the grid is still visible after vim")
        pumpFor(0.5)

        XCTAssertTrue(session.submit("python3"))
        XCTAssertTrue(pump { self.session.mode == .grid(.allowlisted) }, "python3 did not switch the pane to the grid")
        XCTAssertFalse(engine.view.isHidden, "the grid is hidden while python3 runs")
        XCTAssertEqual(engine.view.frame, pane.bounds.insetBy(dx: TerminalPaneView.gridInset, dy: TerminalPaneView.gridInset), "the grid does not fill the pane minus its inset")
        pumpFor(0.8)
        for character in "exit()" { session.sendKeys(.text(String(character))) }
        session.sendKeys(.enter)
        XCTAssertTrue(pump { !self.session.mode.isGrid }, "the pane did not come back to blocks after exit()")
        XCTAssertTrue(pump { self.blocks.count == 9 && self.blocks.last?.isRunning == false && self.blocks.last?.output != nil })
        XCTAssertEqual(blocks.last?.output, .empty, "the REPL's screen is not kept as block text")
        XCTAssertTrue(engine.view.isHidden, "the grid is still visible after python3")
        pumpFor(0.5)

        XCTAssertEqual(blocks.map(\.command), [
            "cd ~/repos", "ls -G", "ls /nope", "printf 'a\\nb\\nc\\n'", "echo \"abc\ndef\"", "sleep 1",
            "for i in 1 2 3; do echo tick$i; sleep 0.3; done", "vim -u NONE", "python3",
        ])

        try saveSnapshot()
    }

    private func press(_ keyCode: UInt16, _ characters: String, shift: Bool = false) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
        pane.editor.keyDown(with: try! XCTUnwrap(event))
        render()
    }

    private func type(_ text: String) {
        pane.editor.string = text
        pane.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        pane.editor.didChangeText()
    }

    func testTabCompletesTheInputLine() {
        waitForPrompt()
        XCTAssertEqual(session.directory, NSHomeDirectory())
        window.makeFirstResponder(pane.editor)

        type("cd r")
        press(48, "\t")
        XCTAssertEqual(pane.editor.string, "cd repos/")
        XCTAssertFalse(pane.editor.isCompletionMenuOpen)

        type("ls .")
        press(48, "\t")
        XCTAssertTrue(pane.editor.isCompletionMenuOpen, "several hidden entries must open the menu")
        let count = pane.editor.completions.count
        XCTAssertGreaterThan(count, 1)
        press(125, "\u{F701}")
        XCTAssertEqual(pane.editor.completionSelection, 1)
        press(48, "\t", shift: true)
        XCTAssertEqual(pane.editor.completionSelection, 0)
        press(53, "\u{1B}")
        XCTAssertFalse(pane.editor.isCompletionMenuOpen)
        XCTAssertEqual(pane.editor.string, "ls .")

        type("")
        XCTAssertTrue(session.submit("sleep 1"))
        XCTAssertTrue(pump { self.session.isCommandRunning })
        XCTAssertTrue(pump { self.pane.editor.forwardsKeys })
        press(48, "\t")
        XCTAssertEqual(pane.editor.string, "")
        XCTAssertFalse(pane.editor.isCompletionMenuOpen)
        XCTAssertTrue(pump { !self.session.isCommandRunning })
    }

    private func pressControl(_ keyCode: UInt16, _ characters: String) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
        pane.editor.keyDown(with: try! XCTUnwrap(event))
        render()
    }

    func testAStaleCompletionMenuNeverCrashesAndEnterSubmitsUnlessSelected() {
        waitForPrompt()
        window.makeFirstResponder(pane.editor)

        type("ls ")
        press(48, "\t")
        XCTAssertTrue(pane.editor.isCompletionMenuOpen)
        pressControl(8, "c")
        XCTAssertEqual(pane.editor.string, "")
        XCTAssertFalse(pane.editor.isCompletionMenuOpen, "the text changed under the menu: it closes")
        press(36, "\r")
        XCTAssertEqual(pane.editor.string, "")

        type("ls .")
        press(48, "\t")
        XCTAssertTrue(pane.editor.isCompletionMenuOpen)
        type("")
        XCTAssertFalse(pane.editor.isCompletionMenuOpen)
        press(48, "\t")

        type("ls .")
        press(48, "\t")
        XCTAssertTrue(pane.editor.isCompletionMenuOpen)
        press(49, " ")
        XCTAssertFalse(pane.editor.isCompletionMenuOpen)
        type("ls .")
        press(48, "\t")
        XCTAssertTrue(pane.editor.isCompletionMenuOpen)
        press(36, "\r")
        XCTAssertFalse(pane.editor.isCompletionMenuOpen)
        XCTAssertEqual(pane.editor.string, "", "Enter submitted the line, no entry was taken")
        XCTAssertTrue(pump { !self.session.isCommandRunning })
    }

    private func key(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
        pane.editor.keyDown(with: try! XCTUnwrap(event))
        render()
    }

    private func typeKeys(_ text: String) {
        for character in text { key(0, String(character)) }
    }

    private func submitByEnter(_ line: String, expecting count: Int) {
        pane.editor.string = ""
        typeKeys(line)
        XCTAssertEqual(pane.editor.string, line)
        key(36, "\r")
        XCTAssertTrue(pump { self.blocks.count == count && self.blocks.last?.isRunning == false && self.blocks.last?.output != nil },
                      "\(line) did not finish: \(blocks.map(\.command))")
        XCTAssertEqual(pane.editor.string, "")
    }

    func testUpArrowWalksHistoryAndControlRSearches() {
        waitForPrompt()
        window.makeFirstResponder(pane.editor)
        submitByEnter("echo one", expecting: 1)
        submitByEnter("echo two", expecting: 2)

        key(126, "\u{F700}")
        XCTAssertEqual(pane.editor.string, "echo two")
        key(126, "\u{F700}")
        XCTAssertEqual(pane.editor.string, "echo one")
        key(125, "\u{F701}")
        XCTAssertEqual(pane.editor.string, "echo two")
        key(125, "\u{F701}")
        XCTAssertEqual(pane.editor.string, "", "past the newest the draft (empty) comes back")

        typeKeys("echo o")
        key(126, "\u{F700}")
        XCTAssertEqual(pane.editor.string, "echo one")
        key(125, "\u{F701}")
        XCTAssertEqual(pane.editor.string, "echo o")

        pane.editor.string = ""
        pane.editor.didChangeText()
        key(15, "r", [.control])
        XCTAssertTrue(pane.editor.isSearchingHistory)
        typeKeys("two")
        XCTAssertEqual(pane.editor.searchResults.first, "echo two")
        key(36, "\r")
        XCTAssertFalse(pane.editor.isSearchingHistory)
        XCTAssertEqual(pane.editor.string, "echo two")
        XCTAssertEqual(blocks.count, 2, "Enter in the search must not run the command")

        key(15, "r", [.control])
        typeKeys("one")
        key(53, "\u{1B}")
        XCTAssertFalse(pane.editor.isSearchingHistory)
        XCTAssertEqual(pane.editor.string, "echo two")
    }

    func testReadlineKeysAndControlD() {
        waitForPrompt()
        window.makeFirstResponder(pane.editor)
        type("echo hello world")
        key(0, "a", [.control])
        XCTAssertEqual(pane.editor.selectedRange().location, 0)
        key(0, "e", [.control])
        XCTAssertEqual(pane.editor.selectedRange().location, 16)
        key(13, "w", [.control])
        XCTAssertEqual(pane.editor.string, "echo hello ")
        key(0, "u", [.control])
        XCTAssertEqual(pane.editor.string, "")
        type("abc def")
        pane.editor.setSelectedRange(NSRange(location: 3, length: 0))
        key(40, "k", [.control])
        XCTAssertEqual(pane.editor.string, "abc")
        pane.editor.setSelectedRange(NSRange(location: 0, length: 0))
        key(2, "d", [.control])
        XCTAssertEqual(pane.editor.string, "bc")
        pumpFor(0.3)
        XCTAssertTrue(session.isRunning)
        key(124, "\u{F703}", [.command])
        XCTAssertEqual(pane.editor.selectedRange().location, 2)
        key(123, "\u{F702}", [.command])
        XCTAssertEqual(pane.editor.selectedRange().location, 0)
    }

    func testMultiLinePasteStaysInTheEditorUntilEnter() throws {
        waitForPrompt()
        window.makeFirstResponder(pane.editor)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("echo a\r\necho b", forType: .string)
        pane.editor.paste(nil)
        XCTAssertEqual(pane.editor.string, "echo a\necho b")
        pumpFor(0.5)
        XCTAssertEqual(blocks.count, 0, "nothing runs until Enter")
        key(36, "\r")
        XCTAssertTrue(pump { !self.blocks.isEmpty && self.blocks.allSatisfy { !$0.isRunning && $0.output != nil } && self.blocks.flatMap { self.texts($0) }.filter { !$0.isEmpty }.count >= 2 },
                      "blocks: \(blocks.map(\.command))")
        XCTAssertEqual(blocks.flatMap { texts($0) }.filter { !$0.isEmpty }, ["a", "b"])
    }

    private var noRange: NSRange { NSRange(location: NSNotFound, length: 0) }

    func testDeadKeyCompositionInTheEditorAndReturnDoesNotSubmit() {
        waitForPrompt()
        window.makeFirstResponder(pane.editor)
        var submitted = [String]()
        pane.editor.onSubmit = { submitted.append($0); return false }
        type("echo ")
        pane.editor.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        XCTAssertTrue(pane.editor.hasMarkedText())
        pane.editor.insertText("é", replacementRange: noRange)
        XCTAssertEqual(pane.editor.string, "echo é")
        XCTAssertFalse(pane.editor.hasMarkedText())

        pane.editor.setMarkedText("e", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        key(36, "\r")
        XCTAssertEqual(pane.editor.string, "echo ée", "Return commits the composition")
        XCTAssertFalse(pane.editor.hasMarkedText())
        XCTAssertEqual(submitted, [], "Return mid-composition must not submit")
        key(36, "\r")
        XCTAssertEqual(submitted, ["echo ée"], "the next Return submits")
    }

    func testDeadKeyInTheSearchAndControlCClosesTheSearchWithoutTouchingTheLine() {
        waitForPrompt()
        window.makeFirstResponder(pane.editor)
        type("echo kept")
        key(15, "r", [.control])
        XCTAssertTrue(pane.editor.isSearchingHistory)
        pane.editor.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        XCTAssertEqual(pane.editor.searchDisplayQuery, "´")
        pane.editor.insertText("é", replacementRange: noRange)
        XCTAssertEqual(pane.editor.searchQuery, "é")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("ab\ncd", forType: .string)
        pane.editor.paste(nil)
        XCTAssertEqual(pane.editor.searchQuery, "éab cd", "paste goes to the query, on one line")
        XCTAssertEqual(pane.editor.string, "echo kept")
        key(8, "c", [.control])
        XCTAssertFalse(pane.editor.isSearchingHistory, "⌃C cancels the search")
        XCTAssertEqual(pane.editor.string, "echo kept", "and does not clear the line (nothing went to the shell)")
    }

    func testDeadKeyWhileACommandRunsSendsTheAccentedCharacter() {
        waitForPrompt()
        window.makeFirstResponder(pane.editor)
        XCTAssertTrue(session.submit("sleep 1"))
        XCTAssertTrue(pump { self.pane.editor.forwardsKeys })
        var sent = [TerminalKey]()
        pane.editor.onKey = { key, _ in sent.append(key) }
        pane.editor.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        XCTAssertTrue(pane.editor.hasMarkedText())
        XCTAssertEqual(sent, [], "nothing is sent while composing")
        pane.editor.insertText("é", replacementRange: noRange)
        XCTAssertEqual(sent, [.text("é")])
        XCTAssertEqual(pane.editor.string, "")
        XCTAssertTrue(pump { !self.session.isCommandRunning })
    }

    func testControlLEmptiesTheList() {
        waitForPrompt()
        window.makeFirstResponder(pane.editor)
        submitByEnter("echo one", expecting: 1)
        key(37, "l", [.control])
        XCTAssertTrue(pump { self.blocks.isEmpty }, "the list was not cleared: \(blocks.map(\.command))")
        XCTAssertTrue(session.isRunning)
        submitByEnter("echo two", expecting: 1)
    }

    private func send(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode)
        let key = try! XCTUnwrap(event)
        if !window.performKeyEquivalent(with: key) { window.firstResponder?.keyDown(with: key) }
        render()
    }

    private func menuItem(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title }, "no \"\(title)\" in \(menu.items.map(\.title))")
    }

    private func perform(_ item: NSMenuItem) {
        XCTAssertTrue(NSApp.sendAction(try! XCTUnwrap(item.action), to: item.target, from: item))
        render()
    }

    func testCommandUpSelectsBlocksAndCommandCCopiesThem() throws {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        waitForPrompt()
        run("echo one", expecting: 1)
        run("echo two", expecting: 2)
        run("echo three", expecting: 3)
        window.makeFirstResponder(pane.editor)

        send(126, "\u{F700}", [.command, .numericPad, .function])
        XCTAssertEqual(pane.list.selectedBlockIDs, [blocks[2].id], "⌘↑ from the editor selects the last block")
        send(126, "\u{F700}", [.command, .numericPad, .function])
        XCTAssertEqual(pane.list.selectedBlockIDs, [blocks[1].id], "the second ⌘↑ selects the one before")

        send(8, "c", [.command])
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "echo two\ntwo")

        send(126, "\u{F700}", [.command, .shift, .numericPad, .function])
        XCTAssertEqual(pane.list.selectedBlockIDs, [blocks[0].id, blocks[1].id], "⇧⌘↑ stretches the selection")
        send(8, "c", [.command])
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "echo one\none\n\necho two\ntwo")
        send(8, "C", [.command, .shift])
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "echo one\n\necho two")
        send(8, "C", [.command, .shift, .option])
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "one\n\ntwo")

        send(53, "\u{1B}", [])
        XCTAssertTrue(pane.list.selectedBlockIDs.isEmpty)
        XCTAssertTrue(window.firstResponder === pane.editor, "Esc returns the focus to the input line")
        send(126, "\u{F700}", [.command, .numericPad, .function])
        XCTAssertEqual(pane.list.selectedBlockIDs, [blocks[2].id])
        send(0, "x", [])
        XCTAssertTrue(pane.list.selectedBlockIDs.isEmpty)
        XCTAssertTrue(window.firstResponder === pane.editor)
        XCTAssertEqual(pane.editor.string, "x", "the typed key reached the input line")
    }

    func testBlockMenuCopiesTheOutputAndRunsTheCommandAgain() throws {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        waitForPrompt()
        run("printf 'x\\ny\\n'", expecting: 1)
        let id = try XCTUnwrap(blocks.first?.id)
        let menu = pane.list.menu(forBlock: id)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), [
            "Copiar comando", "Copiar saída", "Copiar comando e saída", "Executar de novo", "Ir para o topo do bloco", "Ir para o fim do bloco",
        ])
        XCTAssertEqual(pane.list.selectedBlockIDs, [id], "opening the menu selects the block")
        perform(try menuItem("Copiar saída", in: menu))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "x\ny")
        perform(try menuItem("Copiar comando", in: menu))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "printf 'x\\ny\\n'")
        perform(try menuItem("Executar de novo", in: menu))
        XCTAssertTrue(pump { self.blocks.count == 2 && self.blocks.last?.isRunning == false && self.blocks.last?.output != nil })
        XCTAssertEqual(blocks.last?.command, "printf 'x\\ny\\n'")
        perform(try menuItem("Ir para o topo do bloco", in: menu))
        perform(try menuItem("Ir para o fim do bloco", in: menu))
    }

    func testFindBarSearchesCommandsAndOutputs() throws {
        waitForPrompt()
        run("echo needle", expecting: 1)
        run("echo hay", expecting: 2)
        window.makeFirstResponder(pane.editor)
        send(3, "f", [.command])
        XCTAssertTrue(pane.list.isFindOpen)
        pane.list.setQuery("needle")
        send(5, "g", [.command])
        send(5, "g", [.command, .shift])
        pane.list.setQuery("hay")
        send(5, "g", [.command])
        pane.list.closeFind()
        XCTAssertFalse(pane.list.isFindOpen)
        XCTAssertTrue(window.firstResponder === pane.editor)
    }

    func testResetWithAnOpenSearchDoesNotCrashAndClosesIt() throws {
        waitForPrompt()
        run("echo needle", expecting: 1)
        run("echo needle again", expecting: 2)
        window.makeFirstResponder(pane.editor)
        send(3, "f", [.command])
        pane.list.setQuery("needle")
        send(5, "g", [.command])
        XCTAssertTrue(pane.list.isFindOpen)

        pane.list.reset()
        XCTAssertFalse(pane.list.isFindOpen, "the search closed with the list it searched")
        pane.refreshLive()
        render()

        pane.list.showFind()
        pane.list.setQuery("needle")
        pane.detach()
        pane.attach(engine: engine, session: session)
        pane.refreshLive()
        render()
        XCTAssertFalse(pane.list.isFindOpen)
        XCTAssertEqual(pane.list.blockCount, 2, "the blocks are back after attaching again")
    }

    func testOptionAndDeadKeysOnASelectedBlockReachTheEditor() throws {
        waitForPrompt()
        run("echo one", expecting: 1)
        window.makeFirstResponder(pane.editor)
        send(126, "\u{F700}", [.command, .numericPad, .function])
        XCTAssertEqual(pane.list.selectedBlockIDs, [blocks[0].id])
        send(14, "", [.option])
        XCTAssertTrue(pane.list.selectedBlockIDs.isEmpty, "the dead key left the block selection")
        XCTAssertTrue(window.firstResponder === pane.editor, "the dead key moved the focus to the input line")
        send(14, "e", [])
        XCTAssertTrue(pane.editor.string.contains("e"), "the next key reached the editor: \(pane.editor.string)")

        type("")
        send(126, "\u{F700}", [.command, .numericPad, .function])
        send(0, "å", [.option])
        XCTAssertEqual(pane.editor.string, "å", "an ⌥ key that makes text is typed into the input line")
    }

    func testTwentyThousandLinesAreVirtualized() throws {
        waitForPrompt()
        for index in 1...40 { run(":", expecting: index) }
        let start = Date()
        XCTAssertTrue(session.submit("seq 1 20000"))
        let done = pump(30) { self.blocks.count == 41 && self.blocks.last?.isRunning == false && self.blocks.last?.output != nil }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(done, "seq 1 20000 did not finish")
        XCTAssertLessThan(elapsed, 5, "the block took \(elapsed) s")
        XCTAssertEqual(blocks.last?.output?.lines.count, 20000)
        XCTAssertEqual(pane.list.blockCount, 41)
        XCTAssertLessThan(pane.list.rowViewCount, 25, "\(pane.list.rowViewCount) row views for 41 blocks: not virtualized")
        XCTAssertGreaterThan(pane.list.rowViewCount, 0)
    }

    private func saveSnapshot() throws {
        render()
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: Self.snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }
}

@MainActor
final class TerminalSplitSmokeTests: XCTestCase {
    private var window: NSWindow!
    private var workspace: TerminalWorkspace!
    private var remembered: String?

    override func setUp() async throws {
        let home = NSHomeDirectory()
        let integrationURL = try XCTUnwrap(
            Bundle.main.url(forResource: "ShellIntegration", withExtension: nil), "the app bundle has no ShellIntegration folder")
        let memory = TerminalDirectory.Memory(load: { [unowned self] in remembered }, save: { [unowned self] in remembered = $0 })
        workspace = TerminalWorkspace(memory: memory, home: home) { directory in
            let shell = TerminalShell.resolve(shellVariable: "/bin/zsh")
            let env = TerminalEnvironment.build(
                base: ProcessInfo.processInfo.environment, shell: shell, home: home, user: NSUserName(), version: "test")
            let session = TerminalSession(
                shell: shell, environment: env, directory: directory, integration: ShellIntegration(directory: integrationURL),
                integrationEnabled: { true }, nativeBlocks: { true }
            ) { SwiftTermEngine() }
            session.measureHead = { [weak session] range in
                guard let engine = session?.engine as? SwiftTermEngine else { return 1 }
                return BlockText.lineCount(engine.rows(range))
            }
            return session
        }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TerminalTab(workspace: workspace))
        window.orderBack(nil)
        workspace.openFirstIfNeeded()
        render()
    }

    override func tearDown() async throws {
        workspace?.closeAll(grace: 0.2)
        window?.orderOut(nil)
    }

    private func render() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    @discardableResult
    private func pump(_ timeout: TimeInterval = 15, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            render()
            if condition() { return true }
        }
        render()
        return condition()
    }

    private func panes() -> [TerminalPaneView] {
        var found = [TerminalPaneView]()
        func walk(_ view: NSView) {
            if let pane = view as? TerminalPaneView { found.append(pane) }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
        return found
    }

    private func hosts() -> [TerminalHostView] {
        var found = [TerminalHostView]()
        func walk(_ view: NSView) {
            if let host = view as? TerminalHostView { found.append(host) }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
        return found
    }

    private func pane(of session: TerminalSession) -> TerminalPaneView? {
        hosts().first { $0.session === session }?.subviews.compactMap { $0 as? TerminalPaneView }.first
    }

    private func editorHasKeyboard(_ session: TerminalSession) -> Bool {
        guard let pane = pane(of: session) else { return false }
        return window.firstResponder === pane.editor
    }

    private func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
        return window.performKeyEquivalent(with: event)
    }

    private func waitForPrompt(_ session: TerminalSession) {
        XCTAssertTrue(pump { session.isRunning && !session.promptLines.isEmpty }, "the shell never showed a prompt")
    }

    func testPaneKeysWorkFromTheInputLine() throws {
        let first = try XCTUnwrap(workspace.selected)
        waitForPrompt(first)
        XCTAssertTrue(pump { self.editorHasKeyboard(first) }, "the first pane's input line never got the keyboard")

        XCTAssertTrue(first.submit("cd /private/tmp"))
        XCTAssertTrue(pump { first.blocks.blocks.count == 1 && first.blocks.blocks.last?.isRunning == false })

        XCTAssertTrue(key("d", code: 2, .command), "⌘D was not handled with the keyboard in the editor")
        XCTAssertEqual(workspace.layout.selectedTab?.sessions.count, 2)
        let second = try XCTUnwrap(workspace.selected)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertTrue(pump { self.panes().count == 2 }, "two pane views were not on screen")
        XCTAssertTrue(pump { self.editorHasKeyboard(second) }, "the new pane's editor did not get the keyboard")
        waitForPrompt(second)
        XCTAssertTrue(second.submit("pwd"))
        XCTAssertTrue(pump { second.blocks.blocks.count == 1 && second.blocks.blocks.last?.output != nil && second.blocks.blocks.last?.isRunning == false })
        let printed = second.blocks.blocks.last?.output?.lines.map(\.text).filter { !$0.isEmpty }
        XCTAssertEqual(printed, ["/private/tmp"], "the new pane did not open in the focused pane's folder")

        let widthBefore = try XCTUnwrap(pane(of: first)).frame.width
        let path = try XCTUnwrap(workspace.layout.selectedTab?.dividers.first?.path)
        workspace.resize(path, to: 0.3)
        XCTAssertTrue(pump { abs(self.pane(of: first)!.frame.width - widthBefore) > 100 }, "the divider did not resize the pane")

        XCTAssertTrue(key("\u{F702}", code: 123, [.command, .option]))
        XCTAssertEqual(workspace.selectedID, first.id)
        XCTAssertTrue(pump { self.editorHasKeyboard(first) }, "the keyboard did not follow the focus")

        XCTAssertTrue(key("d", code: 2, [.command, .shift]))
        XCTAssertEqual(workspace.layout.selectedTab?.sessions.count, 3)
        let third = try XCTUnwrap(workspace.selected)
        XCTAssertTrue(pump { self.panes().count == 3 && self.editorHasKeyboard(third) })

        let before = workspace.selectedID
        XCTAssertTrue(key("]", code: 30, .command))
        XCTAssertNotEqual(workspace.selectedID, before)
        XCTAssertTrue(pump { self.workspace.selected.map(self.editorHasKeyboard) == true }, "the keyboard did not follow ⌘]")
        XCTAssertTrue(key("[", code: 33, .command))
        XCTAssertEqual(workspace.selectedID, before)
        XCTAssertTrue(pump { self.editorHasKeyboard(third) })

        XCTAssertTrue(key("\r", code: 36, [.command, .shift]))
        XCTAssertEqual(workspace.layout.selectedTab?.maximized, true)
        XCTAssertTrue(pump { self.panes().count == 1 })
        XCTAssertTrue(key("\r", code: 36, [.command, .shift]))
        XCTAssertEqual(workspace.layout.selectedTab?.maximized, false)
        XCTAssertTrue(pump { self.panes().count == 3 && self.editorHasKeyboard(third) })

        XCTAssertTrue(key("w", code: 13, .command))
        XCTAssertEqual(workspace.layout.selectedTab?.sessions.count, 2)
        XCTAssertTrue(pump { self.panes().count == 2 })
        let remaining = try XCTUnwrap(workspace.selected)
        XCTAssertTrue(pump { self.editorHasKeyboard(remaining) }, "the keyboard did not go to the pane that is left in focus")

        XCTAssertTrue(key("t", code: 17, .command))
        XCTAssertEqual(workspace.layout.tabs.count, 2)
        XCTAssertTrue(pump { self.workspace.selected.map(self.editorHasKeyboard) == true })
        XCTAssertTrue(key("1", code: 18, .command))
        XCTAssertEqual(workspace.layout.selectedTabID, workspace.layout.tabs.first?.id)
    }
}
