import Foundation

/// Where the terminal's cursor was when a mark went by. Rows count from the first line the terminal ever had, so they stay true
/// when old lines leave the scrollback; they are not viewport rows.
public struct BlockAnchor: Equatable, Sendable {
    public var row: Int
    public var column: Int
    /// The first row of the live screen (the last `rows` rows of the buffer).
    public var liveTop: Int

    public init(row: Int, column: Int, liveTop: Int = 0) {
        self.row = row
        self.column = column
        self.liveTop = liveTop
    }
}

/// One command and its output.
public struct TerminalBlock: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case running
        /// Ended with the shell's own code (130 after Ctrl-C).
        case finished(Int)
        /// The shell never said how it ended (killed, or the next prompt came first).
        case lost
    }

    public let id: Int
    public var command: String
    public var directory: String?
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: Status
    /// The row where the prompt starts. The row above it is the blank one the header sits on.
    public var promptRow: Int
    /// The first row of the output.
    public var outputStart: Int
    /// Just after the last row of the output; nil while it runs.
    public var outputEnd: Int?
    /// How many lines the prompt and the typed command take, used to find the block again after a reflow.
    public var headLines: Int

    public var isRunning: Bool { status == .running }

    public var exitCode: Int? {
        if case .finished(let code) = status { return code }
        return nil
    }

    public var duration: TimeInterval? {
        finishedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }

    /// The rows the block covers, header row included, with the end still growing for a running block.
    public func rows(until last: Int) -> Range<Int> {
        (promptRow - 1)..<max(promptRow, outputEnd ?? last)
    }
}

/// Turns the marks of one shell into blocks. Pure: the engine says what happened and where, this keeps the list.
public struct BlockTracker: Equatable, Sendable {
    public static let capacity = 500

    public private(set) var blocks = [TerminalBlock]()
    public private(set) var directory: String?
    /// The alternate screen is up: nothing is tracked until it is left.
    public private(set) var suspended = false

    private var pendingPrompt: Int?
    private var pendingCommand: String?
    private var nextID = 1

    public init() {}

    public var running: TerminalBlock? { blocks.last(where: \.isRunning) }

    /// Applies one event. `anchor` is the cursor where the event's sequence ended; marks that need no place may pass nil.
    public mutating func apply(_ event: ShellEvent, anchor: BlockAnchor?, at date: Date = Date()) {
        switch event {
        case .alternateScreen(let on):
            suspended = on
        case .declined:
            break
        case .directory(let report):
            if let path = TerminalDirectory.path(fromReport: report) { directory = path }
        case .cleared(let scrollback):
            clear(scrollback: scrollback, anchor: anchor)
        case .promptStart:
            guard !suspended, let anchor else { return }
            closeLost(at: anchor, date: date)
            pendingPrompt = anchor.row
            pendingCommand = nil
        case .command(let text):
            guard !suspended else { return }
            pendingCommand = text
        case .commandStart:
            guard !suspended, let anchor, let prompt = pendingPrompt else { return }
            closeLost(at: anchor, date: date)
            let start = anchor.column > 0 ? anchor.row + 1 : anchor.row
            blocks.append(TerminalBlock(
                id: nextID, command: pendingCommand ?? "", directory: directory, startedAt: date, finishedAt: nil,
                status: .running, promptRow: prompt, outputStart: max(start, prompt), outputEnd: nil, headLines: 1))
            nextID += 1
            pendingPrompt = nil
            pendingCommand = nil
            if blocks.count > Self.capacity { blocks.removeFirst(blocks.count - Self.capacity) }
        case .commandEnd(let code):
            // The end of a program that held the alternate screen arrives after it left it; one sent from inside is not its own.
            guard !suspended, let anchor, let index = blocks.lastIndex(where: \.isRunning) else { return }
            let end = anchor.column > 0 ? anchor.row + 1 : anchor.row
            blocks[index].outputEnd = max(end, blocks[index].outputStart)
            blocks[index].finishedAt = date
            if let code { blocks[index].status = .finished(code) } else { blocks[index].status = .lost }
        }
    }

    /// A prompt or a command arrived while one was still running: its end never came.
    private mutating func closeLost(at anchor: BlockAnchor, date: Date) {
        guard let index = blocks.lastIndex(where: \.isRunning) else { return }
        blocks[index].outputEnd = max(anchor.row, blocks[index].outputStart)
        blocks[index].finishedAt = date
        blocks[index].status = .lost
    }

    /// A clear at the prompt (Ctrl-L) redraws the prompt where the cursor went, and no new prompt mark comes: the pending prompt moves
    /// there, so the next command is still a block.
    private mutating func clear(scrollback: Bool, anchor: BlockAnchor?) {
        let liveTop = anchor?.liveTop ?? 0
        if pendingPrompt != nil { pendingPrompt = anchor?.row ?? liveTop }
        if scrollback {
            blocks.removeAll()
        } else {
            blocks.removeAll { ($0.outputEnd ?? Int.max) > liveTop || $0.isRunning }
        }
    }

    /// The scrollback no longer holds rows before `firstRow`: blocks whose header row went with them are dropped.
    public mutating func trim(before firstRow: Int) {
        guard let first = blocks.first, first.promptRow - 1 < firstRow else { return }
        blocks.removeAll { $0.promptRow - 1 < firstRow }
    }

    /// The shell ended: a block still running is closed without a code.
    public mutating func shellEnded(at row: Int, date: Date = Date()) {
        closeLost(at: BlockAnchor(row: row, column: 0), date: date)
    }

    public mutating func setHeadLines(_ lines: Int, id: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].headLines = max(1, lines)
    }

    public mutating func replace(_ blocks: [TerminalBlock]) {
        self.blocks = blocks
    }

    public func block(id: Int?) -> TerminalBlock? {
        guard let id else { return nil }
        return blocks.first { $0.id == id }
    }

    /// The block that holds `row`, the header row and the output included.
    public func block(containing row: Int, lastRow: Int) -> TerminalBlock? {
        blocks.last { $0.rows(until: lastRow).contains(row) }
    }

    /// The block before `selected` (or the last one before `row` when nothing is selected), for ⌘↑.
    public func previous(before selected: Int?, topRow: Int) -> TerminalBlock? {
        if let selected, let index = blocks.firstIndex(where: { $0.id == selected }) {
            return index > 0 ? blocks[index - 1] : nil
        }
        return blocks.last { $0.promptRow - 1 < topRow } ?? blocks.last
    }

    /// The block after `selected` (or the first one below `row`), for ⌘↓.
    public func next(after selected: Int?, bottomRow: Int) -> TerminalBlock? {
        if let selected, let index = blocks.firstIndex(where: { $0.id == selected }) {
            return index + 1 < blocks.count ? blocks[index + 1] : nil
        }
        return blocks.first { $0.promptRow > bottomRow }
    }
}

/// What "Colar de novo" does with a finished block's command. It never presses Enter: the user sees the line and runs it. Only a
/// bracketed paste is typed into the shell (Ctrl-E, Ctrl-U as a best effort to empty the line, then the text between ESC[200~ and
/// ESC[201~), because only then does the line editor take it as text. Without one, the letters would reach whatever mode the editor
/// is in (bash vi command mode runs `v` as edit-and-execute), so nothing is typed: the command goes to the clipboard. Control
/// characters other than newline and tab are dropped either way.
public enum BlockRerun {
    public enum Action: Equatable, Sendable {
        /// Bytes for the pty.
        case type([UInt8])
        /// Text for the clipboard; the user pastes it.
        case copy(String)
    }

    public enum Refusal: Error, Equatable, Sendable {
        case busy
        case empty

        public var message: String {
            switch self {
            case .busy: "O shell está ocupado: espere o comando atual terminar."
            case .empty: "Sem comando para colar de novo."
            }
        }
    }

    public static let copiedNotice = "Comando copiado — cole com ⌘V"

    static let clearLine: [UInt8] = [0x05, 0x15]
    static let pasteStart: [UInt8] = Array("\u{1B}[200~".utf8)
    static let pasteEnd: [UInt8] = Array("\u{1B}[201~".utf8)

    public static func decide(command: String, bracketedPaste: Bool, atPrompt: Bool) -> Result<Action, Refusal> {
        var text = sanitized(command)
        while text.last == "\n" { text.removeLast() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.empty) }
        guard bracketedPaste else { return .success(.copy(text)) }
        guard atPrompt else { return .failure(.busy) }
        return .success(.type(clearLine + pasteStart + Array(text.utf8) + pasteEnd))
    }

    /// C0 controls (ESC included, so the text cannot end the paste itself) other than newline and tab, DEL and C1 controls go.
    static func sanitized(_ command: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in command.unicodeScalars {
            let value = scalar.value
            if value == 0x0A || value == 0x09 || (value >= 0x20 && value != 0x7F && !(0x80...0x9F).contains(value)) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

/// How long a block ran, for its header: "0,3 s", "1,2 s", "42 s", "3 min 5 s", "1 h 2 min".
public enum BlockDuration {
    public static func text(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        let tenths = Int((value * 10).rounded())
        if tenths < 100 {
            return "\(tenths / 10),\(tenths % 10) s"
        }
        let whole = Int(value.rounded())
        if whole < 60 { return "\(whole) s" }
        if whole < 3600 { return "\(whole / 60) min \(whole % 60) s" }
        return "\(whole / 3600) h \(whole % 3600 / 60) min"
    }
}
