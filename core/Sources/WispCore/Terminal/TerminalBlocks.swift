import Foundation

public struct BlockAnchor: Equatable, Sendable {
    public var row: Int
    public var column: Int
    public var liveTop: Int

    public init(row: Int, column: Int, liveTop: Int = 0) {
        self.row = row
        self.column = column
        self.liveTop = liveTop
    }
}

public struct TerminalBlock: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case running
        case finished(Int)
        case lost
    }

    public let id: Int
    public var command: String
    public var directory: String?
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: Status
    public var promptRow: Int
    public var outputStart: Int
    public var outputEnd: Int?
    public var headLines: Int
    public var output: BlockOutput? = nil
    public var prompt: [StyledLine] = []

    public var isRunning: Bool { status == .running }

    public var exitCode: Int? {
        if case .finished(let code) = status { return code }
        return nil
    }

    public var duration: TimeInterval? {
        finishedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }

    public func rows(until last: Int) -> Range<Int> {
        (promptRow - 1)..<max(promptRow, outputEnd ?? last)
    }
}

public struct TerminalActivity: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case running
        case succeeded
        case failed(Int)
    }

    public var state: State
    public var command: String?

    public static let idle = TerminalActivity(state: .idle, command: nil)

    public init(state: State, command: String?) {
        self.state = state
        self.command = command
    }
}

public struct BlockTracker: Equatable, Sendable {
    public static let capacity = 500

    public private(set) var blocks = [TerminalBlock]()
    public private(set) var directory: String?
    public private(set) var suspended = false

    private var pendingPrompt: Int?
    private var pendingCommand: String?
    private var nextID = 1

    public init() {}

    public var running: TerminalBlock? { blocks.last(where: \.isRunning) }

    public var activity: TerminalActivity {
        guard let last = blocks.last else { return .idle }
        let command = last.command.isEmpty ? nil : last.command
        switch last.status {
        case .running: return TerminalActivity(state: .running, command: command)
        case .finished(0): return TerminalActivity(state: .succeeded, command: command)
        case .finished(let code): return TerminalActivity(state: .failed(code), command: command)
        case .lost: return TerminalActivity(state: .idle, command: command)
        }
    }

    public mutating func apply(_ event: ShellEvent, anchor: BlockAnchor?, at date: Date = Date()) {
        switch event {
        case .alternateScreen(let on):
            suspended = on
        case .declined, .promptEnd, .mouseTracking, .historyFile:
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
            guard !suspended, let anchor, let index = blocks.lastIndex(where: \.isRunning) else { return }
            let end = anchor.column > 0 ? anchor.row + 1 : anchor.row
            blocks[index].outputEnd = max(end, blocks[index].outputStart)
            blocks[index].finishedAt = date
            if let code { blocks[index].status = .finished(code) } else { blocks[index].status = .lost }
        }
    }

    private mutating func closeLost(at anchor: BlockAnchor, date: Date) {
        guard let index = blocks.lastIndex(where: \.isRunning) else { return }
        blocks[index].outputEnd = max(anchor.row, blocks[index].outputStart)
        blocks[index].finishedAt = date
        blocks[index].status = .lost
    }

    private mutating func clear(scrollback: Bool, anchor: BlockAnchor?) {
        let liveTop = anchor?.liveTop ?? 0
        if pendingPrompt != nil { pendingPrompt = anchor?.row ?? liveTop }
        if scrollback {
            blocks.removeAll()
        } else {
            blocks.removeAll { ($0.outputEnd ?? Int.max) > liveTop || $0.isRunning }
        }
    }

    public mutating func trim(before firstRow: Int) {
        guard let first = blocks.first, first.promptRow - 1 < firstRow else { return }
        blocks.removeAll { $0.promptRow - 1 < firstRow }
    }

    public mutating func shellEnded(at row: Int, date: Date = Date()) {
        closeLost(at: BlockAnchor(row: row, column: 0), date: date)
    }

    public mutating func setHeadLines(_ lines: Int, id: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].headLines = max(1, lines)
    }

    public mutating func setOutput(_ output: BlockOutput, id: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].output = output
    }

    public mutating func setPrompt(_ prompt: [StyledLine], id: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].prompt = prompt
    }

    public mutating func replace(_ blocks: [TerminalBlock]) {
        self.blocks = blocks
    }

    public func block(id: Int?) -> TerminalBlock? {
        guard let id else { return nil }
        return blocks.first { $0.id == id }
    }

    public func block(containing row: Int, lastRow: Int) -> TerminalBlock? {
        blocks.last { $0.rows(until: lastRow).contains(row) }
    }

    public func index(of id: Int?) -> Int? {
        guard let id else { return nil }
        return blocks.firstIndex { $0.id == id }
    }

    public func previousID(before id: Int?) -> Int? {
        guard let index = index(of: id) else { return blocks.last?.id }
        return index > 0 ? blocks[index - 1].id : nil
    }

    public func nextID(after id: Int?) -> Int? {
        guard let index = index(of: id), index + 1 < blocks.count else { return nil }
        return blocks[index + 1].id
    }

    public func previous(before selected: Int?, topRow: Int) -> TerminalBlock? {
        if let selected, let index = blocks.firstIndex(where: { $0.id == selected }) {
            return index > 0 ? blocks[index - 1] : nil
        }
        return blocks.last { $0.promptRow - 1 < topRow } ?? blocks.last
    }

    public func next(after selected: Int?, bottomRow: Int) -> TerminalBlock? {
        if let selected, let index = blocks.firstIndex(where: { $0.id == selected }) {
            return index + 1 < blocks.count ? blocks[index + 1] : nil
        }
        return blocks.first { $0.promptRow > bottomRow }
    }
}

public enum BlockRerun {
    public enum Action: Equatable, Sendable {
        case type([UInt8])
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
