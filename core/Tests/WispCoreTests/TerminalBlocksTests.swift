import XCTest
@testable import WispCore

final class ShellMarkScannerTests: XCTestCase {
    private static let nonce = "0123456789abcdef0123456789abcdef"

    private func osc(_ body: String, terminator: String = "\u{07}") -> [UInt8] { Array("\u{1B}]\(body)\(terminator)".utf8) }
    private func mark(_ body: String, nonce: String = ShellMarkScannerTests.nonce, terminator: String = "\u{07}") -> [UInt8] {
        osc("6973;\(nonce);\(body)", terminator: terminator)
    }

    private func events(_ bytes: [UInt8], nonce: String? = ShellMarkScannerTests.nonce) -> [ShellEvent] {
        var scanner = ShellMarkScanner(nonce: nonce)
        return scanner.scan(bytes[...]).map(\.event)
    }

    func testParsesTheMarksAndTheExitCode() {
        let stream = mark("A") + mark("C") + mark("D;130") + mark("D")
        XCTAssertEqual(events(stream), [.promptStart, .commandStart, .commandEnd(exitCode: 130), .commandEnd(exitCode: nil)])
    }

    func testBothTerminators() {
        let stream = mark("A", terminator: "\u{1B}\\") + mark("D;0")
        XCTAssertEqual(events(stream), [.promptStart, .commandEnd(exitCode: 0)])
    }

    func testDirectoryAndCommandText() {
        let encoded = Data("git status -sb\nls".utf8).base64EncodedString()
        let stream = mark("cwd=file://mac.local/Users/dev/My%20Project") + mark("cmd=\(encoded)")
        XCTAssertEqual(events(stream), [.directory("file://mac.local/Users/dev/My%20Project"), .command("git status -sb\nls")])
    }

    func testAMarkWithoutTheNonceOrWithAnotherOneIsNothing() {
        let encoded = Data("rm -rf ~".utf8).base64EncodedString()
        let missing = osc("6973;A") + osc("6973;C") + osc("6973;D;0") + osc("6973;cmd=\(encoded)") + osc("6973;cwd=file:///etc")
        XCTAssertEqual(events(missing), [])
        let wrong = "fedcba9876543210fedcba9876543210"
        let forged = mark("A", nonce: wrong) + mark("C", nonce: wrong) + mark("D;0", nonce: wrong) + mark("cmd=\(encoded)", nonce: wrong)
            + mark("A", nonce: String(Self.nonce.dropLast())) + mark("A", nonce: Self.nonce + "0")
        XCTAssertEqual(events(forged), [])
        XCTAssertEqual(events(mark("A"), nonce: nil), [], "a plain shell has no nonce: nothing counts")
        XCTAssertEqual(events(mark("A")), [.promptStart])
    }

    func testPlainOSC133AndOSC7AreLeftToTheTerminal() {
        let stream = osc("133;A") + osc("133;C") + osc("133;D;0") + osc("7;file://h/tmp")
        XCTAssertEqual(events(stream), [])
    }

    func testCommandTextWithoutPaddingAndWithAccents() {
        let encoded = Data("echo ação".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(ShellMarkScanner.decodeCommand(encoded), "echo ação")
        XCTAssertNil(ShellMarkScanner.decodeCommand("!!!"))
    }

    func testASequenceSplitAtEveryByteStillArrivesOnce() {
        let encoded = Data("make test".utf8).base64EncodedString()
        let stream = Array("out".utf8) + mark("cmd=\(encoded)") + mark("C") + Array("x\r\n".utf8) + mark("D;2") + mark("cwd=file:///tmp")
        for cut in 1..<stream.count {
            var scanner = ShellMarkScanner(nonce: Self.nonce)
            let found = scanner.scan(stream[0..<cut]) + scanner.scan(stream[cut...])
            XCTAssertEqual(
                found.map(\.event), [.command("make test"), .commandStart, .commandEnd(exitCode: 2), .directory("file:///tmp")], "cut at \(cut)")
        }
        var scanner = ShellMarkScanner(nonce: Self.nonce)
        var all = [ShellEvent]()
        for byte in stream { all += scanner.scan([byte][...]).map(\.event) }
        XCTAssertEqual(all.count, 4)
    }

    func testOffsetsPointJustAfterEachSequence() {
        let first = mark("C")
        let stream = Array("abc".utf8) + first + Array("def".utf8) + mark("D;0")
        var scanner = ShellMarkScanner(nonce: Self.nonce)
        let found = scanner.scan(stream[...])
        XCTAssertEqual(found.map(\.range), [3..<(3 + first.count), (6 + first.count)..<stream.count])
        XCTAssertFalse(found[0].beganEarlier)
    }

    func testASequenceThatBeganInAnEarlierReadSaysSo() {
        let stream = mark("A")
        var scanner = ShellMarkScanner(nonce: Self.nonce)
        XCTAssertTrue(scanner.scan(stream[0..<3]).isEmpty)
        let found = scanner.scan(stream[3...])
        XCTAssertEqual(found.first?.beganEarlier, true)
        XCTAssertEqual(found.first?.range, 0..<(stream.count - 3))
    }

    func testAlternateScreenAndClears() {
        let stream = Array("\u{1B}[?1049h".utf8) + Array("\u{1B}[?1049l".utf8) + Array("\u{1B}[?25h\u{1B}[2J\u{1B}[3J\u{1B}[?47h\u{1B}[?1;1047l".utf8)
            + Array("\u{1B}[?2004h\u{1B}[?2004l\u{1B}[?1049;2004h".utf8)
        XCTAssertEqual(
            events(stream),
            [.alternateScreen(true), .alternateScreen(false), .cleared(scrollback: false), .cleared(scrollback: true), .alternateScreen(true),
             .alternateScreen(false), .alternateScreen(true)], "bracketed paste is read from the terminal, not from the stream")
    }

    func testDeclinedIsAMarkToo() {
        XCTAssertEqual(events(mark("declined")), [.declined])
        XCTAssertEqual(events(mark("declined", nonce: "fedcba9876543210fedcba9876543210")), [])
    }

    func testOtherSequencesAndPlainTextAreIgnored() {
        let stream = Array("plain \u{1B}[31mred\u{1B}[0m ".utf8) + osc("0;title") + osc("52;c;AAAA") + osc("8;;https://x.test") + osc("6973")
            + mark("Z") + mark("B")
        XCTAssertEqual(events(stream), [])
    }

    func testAnUnterminatedSequenceDoesNotEatTheNextOne() {
        let stream = Array("\u{1B}]6973;".utf8) + mark("C")
        XCTAssertEqual(events(stream), [.commandStart])
    }

    func testAHugeBodyIsAbandonedWithoutGrowing() {
        var scanner = ShellMarkScanner(nonce: Self.nonce)
        _ = scanner.scan(Array("\u{1B}]6973;".utf8)[...])
        XCTAssertTrue(scanner.scan([UInt8](repeating: 0x61, count: 200_000)[...]).isEmpty)
        XCTAssertEqual(scanner.scan(mark("A")[...]).count, 1, "a new sequence starts a clean read")
    }
}

final class ShellStreamTests: XCTestCase {
    private static let nonce = "00112233445566778899aabbccddeeff"

    private func mark(_ body: String, nonce: String = ShellStreamTests.nonce) -> [UInt8] { Array("\u{1B}]6973;\(nonce);\(body)\u{07}".utf8) }

    func testTheHeaderRowGoesBeforeEachPromptAfterTheFirstCommand() {
        var stream = ShellStream(nonce: Self.nonce)
        let first = mark("A") + Array("$ ".utf8)
        XCTAssertFalse(stream.cut(first[...]).pieces.contains(.headerRow), "no command yet: no row")
        let command = mark("C") + Array("out\r\n".utf8) + mark("D;0")
        _ = stream.cut(command[...])
        let prompt = Array("x".utf8) + mark("A") + Array("$ ".utf8)
        let pieces = stream.cut(prompt[...]).pieces
        XCTAssertEqual(pieces, [.bytes(0..<1), .headerRow, .bytes(1..<(1 + mark("A").count)), .event(.promptStart), .bytes((1 + mark("A").count)..<prompt.count)])
    }

    func testForgedMarksAddNoRowAndNoEvent() {
        for nonce in [nil, "ffeeddccbbaa99887766554433221100"] as [String?] {
            var stream = ShellStream(nonce: Self.nonce)
            _ = stream.cut((mark("A") + mark("C") + mark("D;0"))[...])
            let forged = nonce.map { mark("A", nonce: $0) + mark("C", nonce: $0) } ?? Array("\u{1B}]6973;A\u{07}\u{1B}]133;A\u{07}".utf8)
            XCTAssertEqual(stream.cut(forged[...]).pieces, [.bytes(0..<forged.count)], "every byte goes to the terminal, nothing else")
        }
    }

    func testAPlainStreamIsFedAsIs() {
        var stream = ShellStream(nonce: nil)
        let bytes = mark("A") + Array("hi".utf8)
        XCTAssertEqual(stream.cut(bytes[...]).pieces, [.bytes(0..<bytes.count)])
        XCTAssertEqual(stream.cut(ArraySlice<UInt8>()).pieces, [])
    }

    private func fed(_ cut: ShellStreamCut) -> [UInt8] {
        cut.pieces.flatMap { piece -> [UInt8] in
            switch piece {
            case .bytes(let range): Array(cut.bytes[(cut.bytes.startIndex + range.lowerBound)..<(cut.bytes.startIndex + range.upperBound)])
            case .headerRow: Array("⏎".utf8)
            case .event, .resetGrid: []
            }
        }
    }

    func testAPromptMarkSplitAcrossReadsStillGetsItsRow() {
        let before = mark("A") + mark("C") + Array("out\r\n".utf8) + mark("D;0")
        let prompt = Array("x".utf8) + mark("A") + Array("$ ".utf8)
        for cut in 1..<prompt.count {
            var stream = ShellStream(nonce: Self.nonce)
            _ = stream.cut(before[...])
            let first = stream.cut(prompt[0..<cut])
            let second = stream.cut(prompt[cut...])
            XCTAssertEqual(fed(first) + fed(second), Array("x⏎".utf8) + mark("A") + Array("$ ".utf8), "cut at \(cut)")
            XCTAssertEqual((first.pieces + second.pieces).filter { $0 == .event(.promptStart) }.count, 1, "cut at \(cut)")
        }
    }

    func testALongSequenceIsNotHeldBack() {
        var stream = ShellStream(nonce: Self.nonce)
        let open = Array("\u{1B}]6973;\(Self.nonce);cmd=".utf8) + [UInt8](repeating: 0x41, count: 400)
        XCTAssertEqual(stream.cut(open[...]).pieces, [.bytes(0..<open.count)])
    }
}

final class BlockTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func anchor(_ row: Int, _ column: Int = 0, liveTop: Int = 0) -> BlockAnchor { BlockAnchor(row: row, column: column, liveTop: liveTop) }

    private func run(_ tracker: inout BlockTracker, command: String, prompt row: Int, at date: Date) {
        tracker.apply(.promptStart, anchor: anchor(row), at: date)
        tracker.apply(.command(command), anchor: nil, at: date)
        tracker.apply(.commandStart, anchor: anchor(row + 1), at: date)
    }

    func testAssemblesABlockFromTheMarks() {
        var tracker = BlockTracker()
        tracker.apply(.directory("file://mac/Users/dev/app"), anchor: nil)
        run(&tracker, command: "ls -la", prompt: 4, at: t0)
        XCTAssertEqual(tracker.blocks.count, 1)
        XCTAssertTrue(tracker.blocks[0].isRunning)
        XCTAssertEqual(tracker.blocks[0].directory, "/Users/dev/app")
        tracker.apply(.commandEnd(exitCode: 0), anchor: anchor(9), at: t0.addingTimeInterval(1.2))
        let block = tracker.blocks[0]
        XCTAssertEqual(block.command, "ls -la")
        XCTAssertEqual(block.status, .finished(0))
        XCTAssertEqual(block.promptRow, 4)
        XCTAssertEqual(block.outputStart, 5)
        XCTAssertEqual(block.outputEnd, 9)
        XCTAssertEqual(try XCTUnwrap(block.duration), 1.2, accuracy: 0.001)
    }

    func testOutputWithoutATrailingNewlineIncludesTheLastRow() {
        var tracker = BlockTracker()
        run(&tracker, command: "printf hi", prompt: 0, at: t0)
        tracker.apply(.commandEnd(exitCode: 0), anchor: anchor(1, 2), at: t0)
        XCTAssertEqual(tracker.blocks[0].outputStart, 1)
        XCTAssertEqual(tracker.blocks[0].outputEnd, 2)
    }

    func testEmptyOutputIsAnEmptyRange() {
        var tracker = BlockTracker()
        run(&tracker, command: "true", prompt: 0, at: t0)
        tracker.apply(.commandEnd(exitCode: 0), anchor: anchor(1), at: t0)
        XCTAssertEqual(tracker.blocks[0].outputStart, tracker.blocks[0].outputEnd)
    }

    func testAProgramThatDiesInTheAlternateScreenDoesNotFreezeTheTracker() {
        var tracker = BlockTracker()
        tracker.apply(.alternateScreen(true), anchor: nil)
        XCTAssertTrue(tracker.suspended)
        run(&tracker, command: "ls", prompt: 3, at: t0)
        XCTAssertFalse(tracker.suspended, "a new prompt means the full-screen program is gone")
        tracker.apply(.commandEnd(exitCode: 0), anchor: anchor(6), at: t0)
        XCTAssertEqual(tracker.blocks.count, 1)
        XCTAssertEqual(tracker.blocks[0].command, "ls")
        XCTAssertEqual(tracker.blocks[0].outputStart, 4)
        XCTAssertEqual(tracker.blocks[0].outputEnd, 6)
        XCTAssertEqual(tracker.blocks[0].status, .finished(0))
    }

    func testCtrlCEndsWith130() {
        var tracker = BlockTracker()
        run(&tracker, command: "sleep 100", prompt: 0, at: t0)
        tracker.apply(.commandEnd(exitCode: 130), anchor: anchor(2), at: t0.addingTimeInterval(3))
        XCTAssertEqual(tracker.blocks[0].exitCode, 130)
        XCTAssertNil(tracker.running)
    }

    func testAPromptWithoutACommandMakesNoBlock() {
        var tracker = BlockTracker()
        tracker.apply(.promptStart, anchor: anchor(0))
        tracker.apply(.promptStart, anchor: anchor(2))
        XCTAssertTrue(tracker.blocks.isEmpty)
    }

    func testAMissingEndIsClosedWhenTheNextPromptArrives() {
        var tracker = BlockTracker()
        run(&tracker, command: "make", prompt: 0, at: t0)
        tracker.apply(.promptStart, anchor: anchor(7), at: t0.addingTimeInterval(5))
        XCTAssertEqual(tracker.blocks[0].status, .lost)
        XCTAssertEqual(tracker.blocks[0].outputEnd, 7)
        XCTAssertNil(tracker.blocks[0].exitCode)
    }

    func testAShellThatDiesLeavesALostBlock() {
        var tracker = BlockTracker()
        run(&tracker, command: "kill -9 $$", prompt: 0, at: t0)
        tracker.shellEnded(at: 3, date: t0.addingTimeInterval(1))
        XCTAssertEqual(tracker.blocks[0].status, .lost)
    }

    func testAlternateScreenSuspendsTrackingUntilItEnds() {
        var tracker = BlockTracker()
        run(&tracker, command: "vim", prompt: 0, at: t0)
        tracker.apply(.alternateScreen(true), anchor: nil)
        tracker.apply(.command("ls"), anchor: nil, at: t0)
        tracker.apply(.commandStart, anchor: anchor(4), at: t0)
        XCTAssertTrue(tracker.suspended)
        tracker.apply(.alternateScreen(false), anchor: nil)
        XCTAssertFalse(tracker.suspended)
        XCTAssertEqual(tracker.blocks.count, 1, "the editor is one block")
        XCTAssertEqual(tracker.blocks[0].command, "vim")
        XCTAssertTrue(tracker.blocks[0].isRunning, "a command inside the alternate screen is not a block of its own")
    }

    func testTheEndOfAProgramThatHeldTheAlternateScreenStillCounts() {
        var tracker = BlockTracker()
        run(&tracker, command: "htop", prompt: 0, at: t0)
        tracker.apply(.alternateScreen(true), anchor: nil)
        tracker.apply(.alternateScreen(false), anchor: nil)
        tracker.apply(.commandEnd(exitCode: 0), anchor: anchor(1), at: t0.addingTimeInterval(60))
        XCTAssertEqual(tracker.blocks[0].status, .finished(0))
    }

    func testACommandWithoutAPromptMarkIsIgnored() {
        var tracker = BlockTracker()
        tracker.apply(.command("ssh host"), anchor: nil)
        tracker.apply(.commandStart, anchor: anchor(3))
        XCTAssertTrue(tracker.blocks.isEmpty)
    }

    func testTrimDropsBlocksWhoseHeaderLeftTheScrollback() {
        var tracker = BlockTracker()
        run(&tracker, command: "a", prompt: 2, at: t0)
        tracker.apply(.commandEnd(exitCode: 0), anchor: anchor(4), at: t0)
        run(&tracker, command: "b", prompt: 6, at: t0)
        tracker.apply(.commandEnd(exitCode: 0), anchor: anchor(8), at: t0)
        tracker.trim(before: 1)
        XCTAssertEqual(tracker.blocks.count, 2)
        tracker.trim(before: 2)
        XCTAssertEqual(tracker.blocks.map(\.command), ["b"], "the header row of a is row 1, gone")
    }

    func testClearingTheScreenDropsWhatItBlankedAndTheScrollbackDropsAll() {
        var tracker = BlockTracker()
        run(&tracker, command: "a", prompt: 0, at: t0)
        tracker.apply(.commandEnd(exitCode: 0), anchor: anchor(2), at: t0)
        run(&tracker, command: "b", prompt: 10, at: t0)
        tracker.apply(.commandEnd(exitCode: 0), anchor: anchor(12), at: t0)
        tracker.apply(.cleared(scrollback: false), anchor: anchor(12, liveTop: 8))
        XCTAssertEqual(tracker.blocks.map(\.command), ["a"])
        tracker.apply(.cleared(scrollback: true), anchor: anchor(12, liveTop: 8))
        XCTAssertTrue(tracker.blocks.isEmpty)
    }

    func testClearingAtThePromptKeepsItSoTheNextCommandIsABlock() {
        var tracker = BlockTracker()
        tracker.apply(.promptStart, anchor: anchor(10))
        tracker.apply(.cleared(scrollback: false), anchor: anchor(8, liveTop: 8))
        tracker.apply(.command("ls"), anchor: nil)
        tracker.apply(.commandStart, anchor: anchor(9))
        XCTAssertEqual(tracker.blocks.map(\.command), ["ls"])
        XCTAssertEqual(tracker.blocks.first?.promptRow, 8, "the prompt moved to where it was redrawn")
    }

    func testClearingWhileACommandRunsLeavesNoPromptPending() {
        var tracker = BlockTracker()
        run(&tracker, command: "clear", prompt: 0, at: t0)
        tracker.apply(.cleared(scrollback: false), anchor: anchor(0, liveTop: 0))
        tracker.apply(.commandStart, anchor: anchor(1))
        XCTAssertTrue(tracker.blocks.isEmpty, "the running block went with the screen, and no prompt was pending")
    }

    func testCapacityKeepsTheNewest() {
        var tracker = BlockTracker()
        for index in 0..<(BlockTracker.capacity + 5) {
            run(&tracker, command: "c\(index)", prompt: index * 3, at: t0)
            tracker.apply(.commandEnd(exitCode: 0), anchor: anchor(index * 3 + 2), at: t0)
        }
        XCTAssertEqual(tracker.blocks.count, BlockTracker.capacity)
        XCTAssertEqual(tracker.blocks.last?.command, "c\(BlockTracker.capacity + 4)")
    }

    func testNavigationBetweenBlocks() {
        var tracker = BlockTracker()
        for (index, row) in [2, 10, 20].enumerated() {
            run(&tracker, command: "c\(index)", prompt: row, at: t0)
            tracker.apply(.commandEnd(exitCode: 0), anchor: anchor(row + 3), at: t0)
        }
        let ids = tracker.blocks.map(\.id)
        XCTAssertEqual(tracker.previous(before: ids[2], topRow: 0)?.id, ids[1])
        XCTAssertNil(tracker.previous(before: ids[0], topRow: 0))
        XCTAssertEqual(tracker.next(after: ids[0], bottomRow: 0)?.id, ids[1])
        XCTAssertNil(tracker.next(after: ids[2], bottomRow: 0))
        XCTAssertEqual(tracker.previous(before: nil, topRow: 15)?.id, ids[1], "nothing selected: the one above the screen's top")
        XCTAssertEqual(tracker.next(after: nil, bottomRow: 12)?.id, ids[2])
        XCTAssertEqual(tracker.block(containing: 12, lastRow: 30)?.id, ids[1])
    }

    func testTheDirectoryOfTheNextBlockFollowsOSC7() {
        var tracker = BlockTracker()
        tracker.apply(.directory("file://h/tmp/one"), anchor: nil)
        run(&tracker, command: "cd ../two", prompt: 0, at: t0)
        tracker.apply(.directory("file://h/tmp/two"), anchor: nil)
        tracker.apply(.commandEnd(exitCode: 0), anchor: anchor(1), at: t0)
        run(&tracker, command: "pwd", prompt: 3, at: t0)
        XCTAssertEqual(tracker.blocks.map { $0.directory }, ["/tmp/one", "/tmp/two"])
    }

    func testDurationText() {
        XCTAssertEqual(BlockDuration.text(0.04), "0,0 s")
        XCTAssertEqual(BlockDuration.text(1.2), "1,2 s")
        XCTAssertEqual(BlockDuration.text(9.96), "10 s")
        XCTAssertEqual(BlockDuration.text(42.4), "42 s")
        XCTAssertEqual(BlockDuration.text(185), "3 min 5 s")
        XCTAssertEqual(BlockDuration.text(3720), "1 h 2 min")
    }
}

final class BlockTextTests: XCTestCase {
    private func rows(_ items: [(String, Bool)], from first: Int = 0) -> [ScreenRow] {
        items.enumerated().map { ScreenRow(row: first + $0.offset, text: $0.element.0, isWrapped: $0.element.1) }
    }

    func testOutputJoinsWrappedRowsAndTrimsTheEnds() {
        let screen = rows([("hello wor", false), ("ld  ", true), ("second   ", false), ("", false), ("", false)])
        XCTAssertEqual(BlockText.output(screen), "hello world\nsecond")
    }

    func testReanchorFindsBlocksByTheirCommandAfterAReflow() {
        func block(_ id: Int, _ command: String, prompt: Int, status: TerminalBlock.Status = .finished(0)) -> TerminalBlock {
            TerminalBlock(
                id: id, command: command, directory: nil, startedAt: Date(), finishedAt: Date(), status: status, promptRow: prompt,
                outputStart: prompt + 1, outputEnd: prompt + 3, headLines: 1)
        }
        let before = [block(1, "ls", prompt: 1), block(2, "ls", prompt: 5), block(3, "echo done", prompt: 9, status: .running)]
        let screen = rows([
            ("", false),
            ("~ % ls", false), ("a", false), ("b", false), ("", false),
            ("~ % l", false), ("s", true), ("a very long output line", false), ("that wrapped", true), ("", false),
            ("~ % echo done", false), ("done", false),
        ])
        let after = BlockText.reanchor(before, rows: screen)
        XCTAssertEqual(after.map(\.id), [1, 2, 3])
        XCTAssertEqual(after.map(\.promptRow), [1, 5, 10])
        XCTAssertEqual(after.map(\.outputStart), [2, 7, 11])
        XCTAssertEqual(after[0].outputEnd, 4, "ends on the blank row above the next prompt")
        XCTAssertEqual(after[1].outputEnd, 9)
        XCTAssertNil(after[2].outputEnd, "still running")
    }

    private func finished(_ id: Int, _ command: String, prompt: Int, headLines: Int = 1) -> TerminalBlock {
        TerminalBlock(
            id: id, command: command, directory: nil, startedAt: Date(), finishedAt: Date(), status: .finished(0), promptRow: prompt,
            outputStart: prompt + headLines, outputEnd: prompt + headLines + 1, headLines: headLines)
    }

    func testReanchorMatchesThePromptLineNotOutputThatContainsTheCommand() {
        let before = [finished(1, "echo tools", prompt: 0), finished(2, "ls", prompt: 3)]
        let screen = rows([
            ("~ % echo tools", false), ("tools", false), ("", false),
            ("~ % ls", false), ("a", false),
        ])
        let after = BlockText.reanchor(before, rows: screen)
        XCTAssertEqual(after.map(\.id), [1, 2])
        XCTAssertEqual(after.map(\.promptRow), [0, 3], "\"tools\" ends with \"ls\" but is output, not a prompt")
        XCTAssertEqual(after[0].outputStart, 1)
        XCTAssertEqual(after[0].outputEnd, 2)
    }

    func testReanchorDropsABlockWithTwoPossiblePromptLines() {
        let before = [finished(1, "cat notes", prompt: 0), finished(2, "ls", prompt: 4), finished(3, "pwd", prompt: 7)]
        let screen = rows([
            ("~ % cat notes", false), ("", false), ("try ls", false), ("", false),
            ("~ % ls", false), ("a", false), ("", false),
            ("~ % pwd", false), ("/tmp", false),
        ])
        let after = BlockText.reanchor(before, rows: screen)
        XCTAssertEqual(after.map(\.id), [1, 3])
        XCTAssertEqual(after.last?.promptRow, 7)
    }

    func testReanchorFollowsATwoLinePromptAndAMultiLineCommand() {
        let before = [finished(1, "for f in a b\ndo echo $f; done", prompt: 0, headLines: 3)]
        let screen = rows([("~/work", false), ("❯ for f in a b", false), ("for> do echo $f; done", false), ("a", false), ("b", false)])
        let after = BlockText.reanchor(before, rows: screen)
        XCTAssertEqual(after.first?.promptRow, 0)
        XCTAssertEqual(after.first?.outputStart, 3)
    }

    func testMergeTakesTheStateFromTheTrackerAsItIsNow() {
        var running = finished(2, "make", prompt: 10)
        running.status = .running
        running.finishedAt = nil
        running.outputEnd = nil
        let snapshot = [finished(1, "ls", prompt: 0), running]
        var movedOne = snapshot[0]
        movedOne.promptRow = 1
        movedOne.outputStart = 2
        movedOne.outputEnd = 5
        var movedTwo = running
        movedTwo.promptRow = 7
        movedTwo.outputStart = 8
        var ended = running
        ended.status = .finished(2)
        ended.finishedAt = Date(timeIntervalSince1970: 99)
        ended.outputEnd = 12
        var newer = finished(3, "git status", prompt: 13)
        newer.status = .running
        newer.outputEnd = nil
        let merged = BlockText.merge(reanchored: [movedOne, movedTwo], snapshot: snapshot, current: [snapshot[0], ended, newer])
        XCTAssertEqual(merged.map(\.id), [1, 2, 3])
        XCTAssertEqual(merged[0].promptRow, 1)
        XCTAssertEqual(merged[0].outputEnd, 5, "ended before the read: its end was found again")
        XCTAssertEqual(merged[1].promptRow, 7)
        XCTAssertEqual(merged[1].status, .finished(2), "never the snapshot's running")
        XCTAssertEqual(merged[1].exitCode, 2)
        XCTAssertEqual(merged[1].finishedAt, Date(timeIntervalSince1970: 99))
        XCTAssertEqual(merged[1].outputEnd, 12)
        XCTAssertEqual(merged[2], newer, "newer than the snapshot: kept as it is")
    }

    func testMergeDropsWhatWasNotFoundAgainOrIsGoneNow() {
        let snapshot = [finished(1, "a", prompt: 0), finished(2, "b", prompt: 3)]
        XCTAssertEqual(BlockText.merge(reanchored: [snapshot[1]], snapshot: snapshot, current: snapshot).map(\.id), [2])
        XCTAssertEqual(BlockText.merge(reanchored: snapshot, snapshot: snapshot, current: [snapshot[0]]).map(\.id), [1], "trimmed meanwhile")
    }

    func testReanchorDropsABlockItCannotFind() {
        let gone = TerminalBlock(
            id: 1, command: "removed", directory: nil, startedAt: Date(), finishedAt: Date(), status: .finished(0), promptRow: 0,
            outputStart: 1, outputEnd: 2, headLines: 1)
        XCTAssertTrue(BlockText.reanchor([gone], rows: rows([("~ % ls", false), ("x", false)])).isEmpty)
    }
}

final class BlockRerunTests: XCTestCase {
    private let clear: [UInt8] = [0x05, 0x15]

    private func typed(_ text: String) -> [UInt8] { clear + Array("\u{1B}[200~\(text)\u{1B}[201~".utf8) }

    func testWithBracketedPasteTheTextIsPastedAndNeverEntered() {
        XCTAssertEqual(BlockRerun.decide(command: "ls -la", bracketedPaste: true, atPrompt: true), .success(.type(typed("ls -la"))))
        XCTAssertEqual(
            BlockRerun.decide(command: "echo a\necho b\n", bracketedPaste: true, atPrompt: true), .success(.type(typed("echo a\necho b"))))
    }

    func testWithoutBracketedPasteNothingIsTypedTheCommandIsCopied() {
        XCTAssertEqual(BlockRerun.decide(command: "vim notes", bracketedPaste: false, atPrompt: true), .success(.copy("vim notes")))
        XCTAssertEqual(
            BlockRerun.decide(command: "echo a\necho b", bracketedPaste: false, atPrompt: true), .success(.copy("echo a\necho b")),
            "several lines are fine on the clipboard")
        XCTAssertEqual(BlockRerun.decide(command: "make", bracketedPaste: false, atPrompt: false), .success(.copy("make")), "copying needs no prompt")
        XCTAssertEqual(BlockRerun.copiedNotice, "Comando copiado — cole com ⌘V")
    }

    func testControlCharactersAreDroppedSoTheTextCannotEndThePasteOrPressKeys() {
        let hostile = "echo hi\u{1B}[201~\u{03}\rrm -rf ~\u{7F}\u{9B}\tx"
        XCTAssertEqual(
            BlockRerun.decide(command: hostile, bracketedPaste: true, atPrompt: true), .success(.type(typed("echo hi[201~rm -rf ~\tx"))))
        XCTAssertEqual(BlockRerun.decide(command: "a\u{0}b\u{4}", bracketedPaste: false, atPrompt: true), .success(.copy("ab")))
    }

    func testRefusals() {
        XCTAssertEqual(BlockRerun.decide(command: "ls", bracketedPaste: true, atPrompt: false), .failure(.busy), "never typed while a command runs")
        XCTAssertEqual(BlockRerun.decide(command: "   \n", bracketedPaste: true, atPrompt: true), .failure(.empty))
        XCTAssertEqual(BlockRerun.decide(command: "\u{1B}\u{7}", bracketedPaste: false, atPrompt: true), .failure(.empty))
    }
}

final class ShellIntegrationPlanTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-integration-\(UUID().uuidString)")
        for file in ["zsh/.zshenv", "bash/wisp.bashrc", "fish/fish/vendor_conf.d/wisp.fish"] {
            let url = directory.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testZshGetsTheZdotdirAndKeepsTheOriginal() {
        let plan = ShellIntegration(directory: directory)
        let launch = plan.launch(shell: TerminalShell(path: "/bin/zsh"), environment: ["ZDOTDIR": "/Users/dev/.config/zsh", "HOME": "/Users/dev"], enabled: true)
        XCTAssertTrue(launch.integrated)
        XCTAssertEqual(launch.execName, "-zsh")
        XCTAssertEqual(launch.environment["ZDOTDIR"], directory.path + "/zsh")
        XCTAssertEqual(launch.environment["WISP_ORIG_ZDOTDIR"], "/Users/dev/.config/zsh")
        let plain = plan.launch(shell: TerminalShell(path: "/bin/zsh"), environment: ["HOME": "/Users/dev"], enabled: true)
        XCTAssertNil(plain.environment["WISP_ORIG_ZDOTDIR"], "no original means no variable, so the script unsets ZDOTDIR at the end")
    }

    func testBashStartsAsANonLoginShellWithTheInitFile() {
        let launch = ShellIntegration(directory: directory).launch(shell: TerminalShell(path: "/bin/bash"), environment: [:], enabled: true)
        XCTAssertEqual(launch.execName, "bash")
        XCTAssertEqual(launch.arguments, ["--init-file", directory.path + "/bash/wisp.bashrc"])
    }

    func testFishGetsItsDirectoryFirstInXdgDataDirs() {
        let launch = ShellIntegration(directory: directory).launch(shell: TerminalShell(path: "/opt/homebrew/bin/fish"), environment: ["XDG_DATA_DIRS": "/a:/b"], enabled: true)
        XCTAssertEqual(launch.execName, "-fish")
        XCTAssertEqual(launch.environment["XDG_DATA_DIRS"], directory.path + "/fish:/a:/b")
        XCTAssertEqual(launch.environment["WISP_XDG_DATA_DIRS_ORIG"], "/a:/b")
    }

    func testEachLaunchHandsTheShellItsNonce() {
        let plan = ShellIntegration(directory: directory)
        for path in ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish"] {
            let launch = plan.launch(shell: TerminalShell(path: path), environment: [:], enabled: true, nonce: "abc123")
            XCTAssertEqual(launch.markNonce, "abc123", path)
            XCTAssertEqual(launch.environment[ShellIntegration.nonceVariable], "abc123", path)
        }
        let a = plan.launch(shell: TerminalShell(path: "/bin/zsh"), environment: [:], enabled: true)
        let b = plan.launch(shell: TerminalShell(path: "/bin/zsh"), environment: [:], enabled: true)
        let nonce = try? XCTUnwrap(a.markNonce)
        XCTAssertEqual(nonce?.count, 32)
        XCTAssertTrue(nonce?.allSatisfy { $0.isHexDigit && !$0.isUppercase } ?? false)
        XCTAssertNotEqual(a.markNonce, b.markNonce)
    }

    func testAPlainLaunchCarriesNoNonce() {
        let plan = ShellIntegration(directory: directory)
        let off = plan.launch(shell: TerminalShell(path: "/bin/zsh"), environment: ["WISP_MARK_NONCE": "stale"], enabled: false)
        XCTAssertNil(off.markNonce)
        XCTAssertNil(off.environment["WISP_MARK_NONCE"])
        XCTAssertFalse(plan.launch(shell: TerminalShell(path: "/bin/zsh"), environment: [:], enabled: true, nonce: nil).integrated)
    }

    func testAnythingElseOrDisabledIsAPlainLoginShell() {
        let plan = ShellIntegration(directory: directory)
        for (path, enabled) in [("/bin/sh", true), ("/usr/bin/nu", true), ("/bin/zsh", false)] {
            let launch = plan.launch(shell: TerminalShell(path: path), environment: ["A": "1"], enabled: enabled)
            XCTAssertFalse(launch.integrated, path)
            XCTAssertEqual(launch.environment, ["A": "1"])
            XCTAssertEqual(launch.execName, "-" + (path as NSString).lastPathComponent)
            XCTAssertTrue(launch.arguments.isEmpty)
        }
    }

    func testMissingScriptsFallBackToPlain() {
        let launch = ShellIntegration(directory: directory.appendingPathComponent("nowhere")).launch(
            shell: TerminalShell(path: "/bin/zsh"), environment: [:], enabled: true)
        XCTAssertFalse(launch.integrated)
    }
}

@MainActor
final class TerminalSessionBlocksTests: XCTestCase {
    private var engines = [FakeTerminalEngine]()
    private let t0 = Date(timeIntervalSince1970: 5)

    private func session(integration: ShellIntegration? = nil, enabled: Bool = true) -> TerminalSession {
        TerminalSession(
            shell: TerminalShell(path: "/bin/zsh"), environment: ["HOME": "/home/dev"], directory: "/home/dev",
            integration: integration, integrationEnabled: { enabled }
        ) { [unowned self] in
            let engine = FakeTerminalEngine()
            engines.append(engine)
            return engine
        }
    }

    private func stamp(_ event: ShellEvent, row: Int = 0, column: Int = 0) -> StampedShellEvent {
        StampedShellEvent(event: event, anchor: BlockAnchor(row: row, column: column), date: t0)
    }

    func testEventsBecomeBlocksAndTheDirectoryFollowsOSC7() {
        let session = session()
        session.start()
        var changes = 0
        session.onBlocksChanged = { changes += 1 }
        engines[0].onShellEvents?([
            stamp(.directory("file://mac/tmp/work")), stamp(.promptStart, row: 2), stamp(.command("ls")), stamp(.commandStart, row: 3),
            stamp(.commandEnd(exitCode: 0), row: 5),
        ])
        XCTAssertEqual(session.blocks.blocks.count, 1)
        XCTAssertEqual(session.directory, "/tmp/work", "the strip's name follows the shell's own report")
        XCTAssertEqual(session.name, "work")
        XCTAssertEqual(changes, 1)
    }

    func testRerunTypesTheCommandOnlyAtThePrompt() throws {
        let session = session()
        session.start()
        engines[0].onShellEvents?([stamp(.promptStart, row: 0), stamp(.command("git status"), row: 0), stamp(.commandStart, row: 1)])
        let id = try XCTUnwrap(session.blocks.blocks.first?.id)
        engines[0].bracketedPasteMode = true
        XCTAssertEqual(session.rerun(id), .failure(.busy), "it is still running")
        XCTAssertTrue(engines[0].written.isEmpty)
        engines[0].onShellEvents?([stamp(.commandEnd(exitCode: 1), row: 2)])
        XCTAssertEqual(session.rerun(id), .success(.type([0x05, 0x15] + Array("\u{1B}[200~git status\u{1B}[201~".utf8))))
        XCTAssertEqual(engines[0].written, [0x05, 0x15] + Array("\u{1B}[200~git status\u{1B}[201~".utf8), "never Enter")
    }

    func testRerunPastesWhenTheTerminalHasBracketedPasteOnNow() throws {
        let session = session()
        session.start()
        engines[0].onShellEvents?([
            stamp(.promptStart, row: 0), stamp(.command("for f in a b\ndo echo $f\ndone"), row: 0),
            stamp(.commandStart, row: 1), stamp(.commandEnd(exitCode: 0), row: 4), stamp(.promptStart, row: 6),
        ])
        let id = try XCTUnwrap(session.blocks.blocks.first?.id)
        XCTAssertEqual(session.rerun(id), .success(.copy("for f in a b\ndo echo $f\ndone")), "the terminal has it off: copied")
        XCTAssertTrue(engines[0].written.isEmpty, "nothing typed")
        engines[0].bracketedPasteMode = true
        XCTAssertEqual(session.rerun(id), .success(.type([0x05, 0x15] + Array("\u{1B}[200~for f in a b\ndo echo $f\ndone\u{1B}[201~".utf8))))
        XCTAssertEqual(engines[0].written, [0x05, 0x15] + Array("\u{1B}[200~for f in a b\ndo echo $f\ndone\u{1B}[201~".utf8), "never Enter")
    }

    private func integratedSession() throws -> (TerminalSession, URL) {
        let scripts = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-session-\(UUID().uuidString)")
        let rc = scripts.appendingPathComponent("zsh/.zshenv")
        try FileManager.default.createDirectory(at: rc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "".write(to: rc, atomically: true, encoding: .utf8)
        let session = session(integration: ShellIntegration(directory: scripts))
        session.start()
        return (session, scripts)
    }

    func testADeclinedShellMakesNoBlocksAndFollowsPlainOSC7() throws {
        let (session, scripts) = try integratedSession()
        defer { try? FileManager.default.removeItem(at: scripts) }
        XCTAssertTrue(session.isIntegrated)
        engines[0].onDirectory?("file://mac/tmp/ignored")
        XCTAssertEqual(session.directory, "/home/dev")
        engines[0].onShellEvents?([stamp(.declined), stamp(.directory("file://mac/tmp/one"))])
        XCTAssertFalse(session.isIntegrated)
        XCTAssertEqual(session.directory, "/tmp/one")
        engines[0].onDirectory?("file://mac/tmp/two")
        XCTAssertEqual(session.directory, "/tmp/two", "no hooks: the plain OSC 7 is all there is")
        XCTAssertTrue(session.blocks.blocks.isEmpty)
    }

    func testAPlainOSC7DoesNotMoveAnIntegratedSession() throws {
        let (session, scripts) = try integratedSession()
        defer { try? FileManager.default.removeItem(at: scripts) }
        XCTAssertNotNil(try XCTUnwrap(engines[0].started).launch.markNonce)
        engines[0].onDirectory?("file://evil/etc")
        XCTAssertEqual(session.directory, "/home/dev", "only the nonce's cwd mark moves it")
        engines[0].onShellEvents?([stamp(.directory("file://mac/tmp/real"))])
        XCTAssertEqual(session.directory, "/tmp/real")
    }

    func testSelectionClearsWhenTheBlockIsTrimmed() throws {
        let session = session()
        session.start()
        engines[0].onShellEvents?([
            stamp(.promptStart, row: 2), stamp(.command("a"), row: 2), stamp(.commandStart, row: 3), stamp(.commandEnd(exitCode: 0), row: 4),
        ])
        let id = try XCTUnwrap(session.blocks.blocks.first?.id)
        session.selectBlock(id)
        session.replaceBlocks([])
        XCTAssertNil(session.selectedBlockID)
    }

    func testTheShellEndingClosesARunningBlock() {
        let session = session()
        session.start()
        engines[0].onShellEvents?([stamp(.promptStart, row: 0), stamp(.command("sleep 9"), row: 0), stamp(.commandStart, row: 1)])
        engines[0].onExit?(137)
        XCTAssertEqual(session.blocks.blocks.first?.status, .lost)
    }

    func testReopenStartsWithNoBlocks() {
        let session = session()
        session.start()
        engines[0].onShellEvents?([stamp(.promptStart, row: 0), stamp(.command("a"), row: 0), stamp(.commandStart, row: 1)])
        engines[0].onExit?(0)
        session.reopen()
        XCTAssertTrue(session.blocks.blocks.isEmpty)
    }

    func testTheToggleDecidesAtStartAndIsReadEachTime() throws {
        let scripts = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scripts) }
        let rc = scripts.appendingPathComponent("zsh/.zshenv")
        try FileManager.default.createDirectory(at: rc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "".write(to: rc, atomically: true, encoding: .utf8)
        let on = session(integration: ShellIntegration(directory: scripts), enabled: true)
        on.start()
        XCTAssertTrue(on.isIntegrated)
        XCTAssertEqual(try XCTUnwrap(engines[0].started).env["ZDOTDIR"], scripts.path + "/zsh")
        let off = session(integration: ShellIntegration(directory: scripts), enabled: false)
        off.start()
        XCTAssertFalse(off.isIntegrated)
        XCTAssertNil(try XCTUnwrap(engines[1].started).env["ZDOTDIR"])
    }
}
