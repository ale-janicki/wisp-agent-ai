import XCTest
@testable import WispCore

final class NativeShellStreamTests: XCTestCase {
    private static let nonce = "00112233445566778899aabbccddeeff"

    private func mark(_ body: String) -> [UInt8] { Array("\u{1B}]6973;\(Self.nonce);\(body)\u{07}".utf8) }

    func testMouseTrackingModesAreScanned() {
        var scanner = ShellMarkScanner(nonce: Self.nonce)
        let bytes = Array("\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?1002;1006l\u{1B}[?25h\u{1B}[?1049;1003h".utf8)
        XCTAssertEqual(
            scanner.scan(bytes[...]).map(\.event),
            [.mouseTracking(true), .mouseTracking(true), .alternateScreen(true), .mouseTracking(true)],
            "1006 is only an encoding; 1000 is still on after 1002 is turned off")
    }

    func testTrackingIsOnWhileAnyModeIsAndASplitSequenceCounts() {
        var scanner = ShellMarkScanner(nonce: Self.nonce)
        var events = scanner.scan(Array("\u{1B}[?1000;1002h\u{1B}[?10".utf8)[...]).map(\.event)
        events += scanner.scan(Array("06h\u{1B}[?1000l".utf8)[...]).map(\.event)
        events += scanner.scan(Array("\u{1B}[?1015l\u{1B}[?1006l".utf8)[...]).map(\.event)
        events += scanner.scan(Array("\u{1B}[?1002l".utf8)[...]).map(\.event)
        XCTAssertEqual(events, [.mouseTracking(true), .mouseTracking(true), .mouseTracking(false)])
    }

    func testANewPromptForgetsTheModesAKilledProgramLeftOn() {
        var scanner = ShellMarkScanner(nonce: Self.nonce)
        _ = scanner.scan(Array("\u{1B}[?1000h".utf8)[...])
        _ = scanner.scan(mark("A")[...])
        XCTAssertEqual(scanner.scan(Array("\u{1B}[?1002h\u{1B}[?1002l".utf8)[...]).map(\.event), [.mouseTracking(true), .mouseTracking(false)])
    }

    func testTheBMarkIsThePromptEnd() {
        var scanner = ShellMarkScanner(nonce: Self.nonce)
        let events = scanner.scan((mark("A") + Array("% ".utf8) + mark("B") + mark("C") + mark("D;0"))[...]).map(\.event)
        XCTAssertEqual(events, [.promptStart, .promptEnd, .commandStart, .commandEnd(exitCode: 0)])
    }

    func testABMarkWithAnotherNonceIsNothing() {
        var scanner = ShellMarkScanner(nonce: Self.nonce)
        XCTAssertTrue(scanner.scan(Array("\u{1B}]6973;ffeeddccbbaa99887766554433221100;B\u{07}".utf8)[...]).isEmpty)
    }

    func testResetGridComesBetweenTheCommandStartBytesAndItsEvent() {
        var stream = ShellStream(nonce: Self.nonce, nativeBlocks: true)
        let bytes = mark("A") + Array("% ".utf8) + mark("B") + mark("cmd=bHM=") + mark("C") + Array("out\r\n".utf8) + mark("D;0")
        let pieces = stream.cut(bytes[...]).pieces
        let events = pieces.compactMap { piece -> String? in
            switch piece {
            case .resetGrid: "reset"
            case .event(.promptStart): "A"
            case .event(.promptEnd): "B"
            case .event(.commandStart): "C"
            case .event(.commandEnd): "D"
            default: nil
            }
        }
        XCTAssertEqual(events, ["A", "B", "reset", "C", "D"])
        let reset = pieces.firstIndex(of: .resetGrid)!
        XCTAssertEqual(pieces[reset + 1], .event(.commandStart))
        guard case .bytes(let range) = pieces[reset - 1] else { return XCTFail("the C sequence is fed before the reset: \(pieces)") }
        XCTAssertEqual(Array(bytes[range]), mark("C"))
    }

    func testNativeBlocksAddNoHeaderRowAndOnlyOneResetPerCommand() {
        var stream = ShellStream(nonce: Self.nonce, nativeBlocks: true)
        let first = mark("A") + mark("B") + mark("C") + Array("out\r\n".utf8) + mark("D;0")
        let second = mark("A") + mark("B") + mark("C") + mark("D;1") + mark("A")
        let pieces = stream.cut(first[...]).pieces + stream.cut(second[...]).pieces
        XCTAssertFalse(pieces.contains(.headerRow))
        XCTAssertEqual(pieces.filter { $0 == .resetGrid }.count, 2)
    }

    func testWithoutNativeBlocksNothingIsReset() {
        var stream = ShellStream(nonce: Self.nonce)
        let bytes = mark("A") + mark("C") + Array("out\r\n".utf8) + mark("D;0") + mark("A")
        XCTAssertFalse(stream.cut(bytes[...]).pieces.contains(.resetGrid))
        XCTAssertTrue(stream.cut(bytes[...]).pieces.contains(.headerRow), "the overlay's header row is unchanged")
    }

    func testForgedMarksDoNotResetTheGrid() {
        var stream = ShellStream(nonce: Self.nonce, nativeBlocks: true)
        let forged = Array("\u{1B}]6973;ffeeddccbbaa99887766554433221100;C\u{07}\u{1B}]133;C\u{07}".utf8)
        XCTAssertEqual(stream.cut(forged[...]).pieces, [.bytes(0..<forged.count)])
    }
}

@MainActor
final class NativeSessionTests: XCTestCase {
    private static let scripts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("app/Resources/ShellIntegration")

    private var engines = [FakeTerminalEngine]()

    private func session(shell path: String = "/bin/zsh", native: Bool = true) -> TerminalSession {
        TerminalSession(
            shell: TerminalShell(path: path), environment: ["HOME": "/home/dev", "PATH": "/usr/bin:/bin"], directory: "/tmp",
            integration: ShellIntegration(directory: Self.scripts), nativeBlocks: { native }
        ) { [unowned self] in
            let engine = FakeTerminalEngine()
            engines.append(engine)
            return engine
        }
    }

    private func stamp(_ event: ShellEvent, row: Int = 0, column: Int = 0, capture: BlockOutput? = nil) -> StampedShellEvent {
        StampedShellEvent(event: event, anchor: BlockAnchor(row: row, column: column), capture: capture)
    }

    private func lines(_ texts: String...) -> BlockOutput { BlockOutput(lines: texts.map { StyledLine(text: $0) }) }

    func testZshWithTheFlagIsNativeAndTheLaunchSaysSo() throws {
        let session = session()
        session.start()
        XCTAssertTrue(session.isNative)
        XCTAssertEqual(session.mode, .blocks)
        XCTAssertEqual(engines[0].started?.launch.nativeBlocks, true)
    }

    func testTheFlagOffOrAnotherShellKeepsTheGrid() throws {
        let off = session(native: false)
        off.start()
        XCTAssertFalse(off.isNative)
        XCTAssertEqual(off.mode, .grid(.plainShell))
        XCTAssertEqual(engines[0].started?.launch.nativeBlocks, false)
        let bash = session(shell: "/bin/bash")
        bash.start()
        XCTAssertTrue(bash.isNative, "bash and fish emit the B mark too")
        XCTAssertEqual(bash.mode, .blocks)
        let other = session(shell: "/bin/tcsh")
        other.start()
        XCTAssertFalse(other.isNative, "a shell with no integration keeps the grid")
        XCTAssertEqual(other.mode, .grid(.plainShell))
        XCTAssertFalse(other.submit("ls"))
    }

    func testBeforeTheFirstPromptNothingIsSentAndTheTextIsNotTaken() {
        let session = session()
        session.start()
        XCTAssertFalse(session.submit("ls -G"), "the editor keeps its text")
        XCTAssertTrue(engines[0].written.isEmpty)
        engines[0].bracketedPasteMode = true
        engines[0].onShellEvents?([stamp(.promptStart), stamp(.promptEnd, capture: lines("~ %"))])
        XCTAssertEqual(session.promptLines.map(\.text), ["~ %"])
        XCTAssertTrue(session.submit("ls -G"))
        XCTAssertEqual(engines[0].written, InputSender.bytes(text: "ls -G", bracketedPaste: true))
    }

    func testAContinuationPromptWithNoMarksStillTakesTheNextLine() {
        let session = session()
        session.start()
        engines[0].onShellEvents?([stamp(.promptStart), stamp(.promptEnd, capture: lines("%"))])
        XCTAssertTrue(session.submit("echo 'a"))
        engines[0].written = []
        XCTAssertTrue(session.submit("b'"))
        XCTAssertEqual(engines[0].written, InputSender.bytes(text: "b'", bracketedPaste: false))
        engines[0].written = []
        engines[0].onShellEvents?([stamp(.command("echo 'a\nb'")), stamp(.commandStart, row: 0)])
        XCTAssertFalse(session.submit("nope"), "a command runs: its keys are the program's")
        XCTAssertTrue(engines[0].written.isEmpty)
    }

    func testAPromptWithoutBStillTakesALine() {
        let session = session()
        session.start()
        engines[0].onShellEvents?([stamp(.promptStart)])
        XCTAssertTrue(session.submit("ls"))
    }

    func testPasteIntoARunningCommandHonoursBracketedPasteAndDropsControls() {
        let session = session()
        session.start()
        engines[0].bracketedPasteMode = true
        session.paste("a\u{1B}[201~b\r\nc\td\u{03}")
        XCTAssertEqual(String(decoding: engines[0].written, as: UTF8.self), "\u{1B}[200~a[201~b\rc\td\u{1B}[201~")
        engines[0].written = []
        engines[0].bracketedPasteMode = false
        session.paste("x\ny")
        XCTAssertEqual(String(decoding: engines[0].written, as: UTF8.self), "x\ry")
    }

    func testTheOutputIsFrozenAtDAndThePromptTravelsWithTheBlock() throws {
        let session = session()
        session.start()
        let output = lines("a", "b")
        engines[0].onShellEvents?([
            stamp(.promptStart), stamp(.promptEnd, column: 2, capture: lines("~ %")), stamp(.command("ls")),
            stamp(.commandStart, row: 0),
        ])
        var block = try XCTUnwrap(session.blocks.blocks.first)
        XCTAssertTrue(block.isRunning)
        XCTAssertNil(block.output, "the screen holds it while it runs")
        XCTAssertEqual(block.prompt.map(\.text), ["~ %"])
        XCTAssertTrue(session.isCommandRunning)
        engines[0].onShellEvents?([stamp(.commandEnd(exitCode: 1), row: 2, capture: output)])
        block = try XCTUnwrap(session.blocks.blocks.first)
        XCTAssertEqual(block.output, output)
        XCTAssertEqual(block.exitCode, 1)
        XCTAssertFalse(session.isCommandRunning)
    }

    func testAPromptThatClosesALostBlockFreezesItsOutputToo() throws {
        let session = session()
        session.start()
        engines[0].onShellEvents?([stamp(.promptStart), stamp(.promptEnd), stamp(.command("x")), stamp(.commandStart, row: 0)])
        engines[0].onShellEvents?([stamp(.promptStart, row: 3, capture: lines("partial"))])
        let block = try XCTUnwrap(session.blocks.blocks.first)
        XCTAssertEqual(block.status, .lost)
        XCTAssertEqual(block.output?.plainText, "partial")
    }

    func testTheAlternateScreenSwitchesTheModeAndBack() {
        let session = session()
        session.start()
        engines[0].onShellEvents?([stamp(.promptStart), stamp(.promptEnd), stamp(.command("vim")), stamp(.commandStart)])
        engines[0].onShellEvents?([stamp(.alternateScreen(true))])
        XCTAssertEqual(session.mode, .grid(.alternateScreen))
        engines[0].onShellEvents?([stamp(.alternateScreen(false)), stamp(.commandEnd(exitCode: 0), row: 1, capture: .empty)])
        XCTAssertEqual(session.mode, .blocks)
        XCTAssertEqual(session.blocks.blocks.first?.exitCode, 0, "the end that came after leaving the alternate screen is its own")
    }

    func testAnAllowlistedCommandTakesTheGridAtCAndLeavesAtDWithAnEmptyBlock() throws {
        let session = session()
        session.start()
        engines[0].onShellEvents?([stamp(.promptStart), stamp(.promptEnd), stamp(.command("FOO=1 claude")), stamp(.commandStart)])
        XCTAssertEqual(session.mode, .grid(.allowlisted))
        engines[0].onShellEvents?([stamp(.commandEnd(exitCode: 0), row: 4, capture: lines("the TUI's last screen"))])
        XCTAssertEqual(session.mode, .blocks)
        let block = try XCTUnwrap(session.blocks.blocks.first)
        XCTAssertEqual(block.output, .empty, "the program's screen is not kept as text")
        XCTAssertEqual(block.exitCode, 0)
        engines[0].onShellEvents?([stamp(.promptStart), stamp(.promptEnd), stamp(.command("ls")), stamp(.commandStart)])
        XCTAssertEqual(session.mode, .blocks)
        engines[0].onShellEvents?([stamp(.commandEnd(exitCode: 0), row: 2, capture: lines("a"))])
        XCTAssertEqual(session.blocks.blocks.last?.output, lines("a"), "a plain command still keeps its output")
    }

    func testMouseTrackingTakesTheGridUntilItTurnsOffOrTheCommandEnds() {
        let session = session()
        session.start()
        engines[0].onShellEvents?([stamp(.promptStart), stamp(.promptEnd), stamp(.command("mytool")), stamp(.commandStart)])
        XCTAssertEqual(session.mode, .blocks)
        engines[0].onShellEvents?([stamp(.mouseTracking(true))])
        XCTAssertEqual(session.mode, .grid(.mouseTracking))
        engines[0].onShellEvents?([stamp(.mouseTracking(false))])
        XCTAssertEqual(session.mode, .blocks)
        engines[0].onShellEvents?([stamp(.mouseTracking(true)), stamp(.commandEnd(exitCode: 0), capture: lines("x"))])
        XCTAssertEqual(session.mode, .blocks, "D ends the grid even if tracking was never turned off")
    }

    func testANewPromptLeavesTheAlternateScreenAKilledProgramNeverLeft() {
        let session = session()
        session.start()
        engines[0].onShellEvents?([stamp(.promptStart), stamp(.promptEnd), stamp(.command("mytool")), stamp(.commandStart)])
        engines[0].onShellEvents?([stamp(.alternateScreen(true))])
        XCTAssertEqual(session.mode, .grid(.alternateScreen))
        engines[0].onShellEvents?([stamp(.promptStart)])
        XCTAssertEqual(session.mode, .blocks)
        engines[0].onShellEvents?([stamp(.promptEnd), stamp(.command("ls")), stamp(.commandStart), stamp(.alternateScreen(true))])
        XCTAssertEqual(session.mode, .grid(.alternateScreen))
        engines[0].onShellEvents?([stamp(.commandEnd(exitCode: 130), capture: lines("x"))])
        XCTAssertEqual(session.mode, .blocks, "D resets it too")
    }

    func testToggleGridHoldsUntilTheCommandEndsOrTheyToggleBack() {
        let session = session()
        session.start()
        engines[0].onShellEvents?([stamp(.promptStart), stamp(.promptEnd), stamp(.command("sleep 5")), stamp(.commandStart)])
        session.toggleGrid()
        XCTAssertEqual(session.mode, .grid(.manual))
        engines[0].onShellEvents?([stamp(.alternateScreen(true)), stamp(.alternateScreen(false))])
        XCTAssertEqual(session.mode, .grid(.manual), "a program's own mode change does not undo the person's choice")
        session.toggleGrid()
        XCTAssertEqual(session.mode, .blocks)
        session.toggleGrid()
        engines[0].onShellEvents?([stamp(.commandEnd(exitCode: 0), capture: lines("x"))])
        XCTAssertEqual(session.mode, .blocks, "the end of the command gives the pane back")
        XCTAssertEqual(session.blocks.blocks.first?.output, lines("x"), "a manual grid still keeps the text output")
    }

    func testToggleGridOverAProgramsGridShowsTheBlocksUntilItEnds() {
        let session = session()
        session.start()
        engines[0].onShellEvents?([stamp(.promptStart), stamp(.promptEnd), stamp(.command("vim")), stamp(.commandStart)])
        XCTAssertEqual(session.mode, .grid(.allowlisted))
        session.toggleGrid()
        XCTAssertEqual(session.mode, .blocks)
        engines[0].onShellEvents?([stamp(.commandEnd(exitCode: 0), capture: lines("x"))])
        XCTAssertEqual(session.mode, .blocks)
    }

    func testClearEmptiesTheListWhenItEnds() {
        let session = session()
        session.start()
        engines[0].onShellEvents?([stamp(.promptStart), stamp(.promptEnd), stamp(.command("ls")), stamp(.commandStart)])
        engines[0].onShellEvents?([stamp(.commandEnd(exitCode: 0), capture: lines("a"))])
        engines[0].onShellEvents?([stamp(.promptStart), stamp(.promptEnd), stamp(.command("clear")), stamp(.commandStart)])
        XCTAssertEqual(session.blocks.blocks.count, 2)
        engines[0].onShellEvents?([stamp(.commandEnd(exitCode: 0), capture: .empty)])
        XCTAssertTrue(session.blocks.blocks.isEmpty)
        engines[0].onShellEvents?([stamp(.promptStart), stamp(.promptEnd), stamp(.command("echo clear")), stamp(.commandStart)])
        engines[0].onShellEvents?([stamp(.commandEnd(exitCode: 0), capture: lines("clear"))])
        XCTAssertEqual(session.blocks.blocks.count, 1)
    }

    func testWhichCommandsClearTheList() {
        for command in ["clear", "  clear -x", "/usr/bin/clear", "tput clear", "tput -T xterm reset", "reset"] {
            XCTAssertTrue(ClearCommand.isClear(command), command)
        }
        for command in ["clear && ls", "clear; ls", "ls | clear", "echo clear", "tput cols", "clearx", "", "cat clear", "clear $(ls)"] {
            XCTAssertFalse(ClearCommand.isClear(command), command)
        }
    }

    func testAProgramsOwnScreenClearDoesNotDropTheRunningBlock() {
        let session = session()
        session.start()
        engines[0].onShellEvents?([stamp(.promptStart), stamp(.promptEnd), stamp(.command("top")), stamp(.commandStart)])
        engines[0].onShellEvents?([stamp(.cleared(scrollback: true))])
        XCTAssertEqual(session.blocks.blocks.count, 1)
        XCTAssertTrue(session.isCommandRunning)
    }

    func testKeysOfARunningCommandGoThroughTheEncoder() {
        let session = session()
        session.start()
        session.sendKeys(.text("c"), control: true)
        session.sendKeys(.up)
        XCTAssertEqual(engines[0].written, [0x03] + Array("\u{1B}[A".utf8))
    }
}
