import Foundation
import Observation

@MainActor @Observable
public final class TerminalSession: Identifiable {
    public enum Phase: Equatable {
        case idle
        case running
        case ended(Int32?)
        case failed(String)
    }

    public nonisolated let id: UUID
    public private(set) var phase: Phase = .idle
    public private(set) var title = ""
    public private(set) var directory: String
    public private(set) var engine: any TerminalEngine
    public private(set) var activity = TerminalActivity.idle
    public private(set) var mode = PaneMode.grid(.plainShell)
    public private(set) var promptLines = [StyledLine]()

    @ObservationIgnored public private(set) var historyFile: String?

    @ObservationIgnored public let shell: TerminalShell
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let integration: ShellIntegration?
    @ObservationIgnored private let integrationEnabled: () -> Bool
    @ObservationIgnored private let nativeBlocksEnabled: () -> Bool
    @ObservationIgnored public private(set) var isNative = false
    @ObservationIgnored private var atPrompt = false
    @ObservationIgnored private var sawPrompt = false
    @ObservationIgnored private var inAlternateScreen = false
    @ObservationIgnored private var runningCommand: String?
    @ObservationIgnored private var mouseTracking = false
    @ObservationIgnored private var ranInGrid = false
    @ObservationIgnored private var manualMode: PaneMode?
    @ObservationIgnored private let allowlist: Set<String>
    @ObservationIgnored public private(set) var blocks = BlockTracker()
    @ObservationIgnored public private(set) var selectedBlockID: Int?
    @ObservationIgnored public private(set) var isIntegrated = false
    @ObservationIgnored public var onBlocksChanged: (() -> Void)?
    @ObservationIgnored public var measureHead: ((Range<Int>) -> Int)?
    @ObservationIgnored private let makeEngine: () -> any TerminalEngine
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var size = TerminalSize.standard
    @ObservationIgnored public var onDirectory: ((String) -> Void)?

    public init(
        id: UUID = UUID(), shell: TerminalShell, environment: [String: String], directory: String,
        integration: ShellIntegration? = nil, integrationEnabled: @escaping () -> Bool = { true },
        nativeBlocks: @escaping () -> Bool = { false }, allowlist: Set<String> = PaneModeDecider.defaultAllowlist,
        makeEngine: @escaping () -> any TerminalEngine
    ) {
        self.id = id
        self.shell = shell
        self.environment = environment
        self.integration = integration
        self.integrationEnabled = integrationEnabled
        nativeBlocksEnabled = nativeBlocks
        self.allowlist = allowlist
        self.directory = directory
        self.makeEngine = makeEngine
        engine = makeEngine()
    }

    public var name: String {
        TerminalSessionName.make(title: title, directory: directory, home: environment["HOME"], shell: shell)
    }

    public var isRunning: Bool { phase == .running }

    public var isCommandRunning: Bool { blocks.running != nil }

    public var home: String? { environment["HOME"] }

    public func start(size: TerminalSize = .standard) {
        guard phase == .idle else { return }
        self.size = size
        launch()
    }

    public func reopen() {
        switch phase {
        case .ended, .failed: break
        case .idle, .running: return
        }
        engine = makeEngine()
        blocks = BlockTracker()
        selectedBlockID = nil
        syncActivity()
        launch()
        onBlocksChanged?()
    }

    public func write(_ bytes: [UInt8]) {
        guard phase == .running else { return }
        engine.write(bytes)
    }

    public func resize(_ size: TerminalSize) {
        self.size = size
        guard phase == .running else { return }
        engine.resize(size)
    }

    public func close() {
        generation += 1
        refreshDirectory()
        if phase == .running { engine.terminate() }
        phase = .idle
    }

    public func refreshDirectory() {
        guard phase == .running, let current = engine.currentDirectory() else { return }
        setDirectory(current)
    }

    private func launch() {
        generation += 1
        let mine = generation
        let engine = engine
        engine.onExit = { [weak self] code in
            guard let self, self.generation == mine else { return }
            self.phase = .ended(code)
            self.blocks.shellEnded(at: self.blocks.running?.outputStart ?? 0)
            self.syncActivity()
            self.onBlocksChanged?()
        }
        engine.onDirectory = { [weak self] path in
            guard let self, self.generation == mine, !self.isIntegrated else { return }
            self.setDirectory(path)
        }
        engine.onFailure = { [weak self] reason in
            guard let self, self.generation == mine else { return }
            self.phase = .failed(Self.failureText(reason))
        }
        engine.onTitle = { [weak self] title in
            guard let self, self.generation == mine else { return }
            self.title = title
        }
        engine.onShellEvents = { [weak self] events in
            guard let self, self.generation == mine else { return }
            self.apply(events)
        }
        var plan = integration?.launch(shell: shell, environment: environment, enabled: integrationEnabled())
            ?? TerminalLaunch(arguments: shell.arguments, execName: shell.loginName, environment: environment, integrated: false)
        isIntegrated = plan.integrated
        isNative = plan.integrated && nativeBlocksEnabled() && ShellIntegration.kind(of: shell) != nil
        plan.nativeBlocks = isNative
        atPrompt = false
        sawPrompt = false
        inAlternateScreen = false
        runningCommand = nil
        mouseTracking = false
        ranInGrid = false
        manualMode = nil
        promptLines = []
        historyFile = nil
        refreshMode()
        do {
            try engine.start(shell: shell, launch: plan, cwd: directory, size: size)
            title = ""
            phase = .running
        } catch {
            phase = .failed(Self.failureText(error.localizedDescription))
        }
    }

    // MARK: Blocks

    private func apply(_ events: [StampedShellEvent]) {
        for stamped in events {
            if case .historyFile(let path) = stamped.event { historyFile = path }
            if stamped.event == .declined {
                isIntegrated = false
                isNative = false
            }
            if isNative, case .cleared = stamped.event { continue }
            let runningBefore = blocks.running?.id
            blocks.apply(stamped.event, anchor: stamped.anchor, at: stamped.date)
            if isNative { applyNative(stamped, runningBefore: runningBefore) }
            if stamped.event == .declined { refreshMode() }
        }
        if let directory = blocks.directory { setDirectory(directory) }
        if !isNative, events.contains(where: { $0.event == .commandStart }), let running = blocks.running, let measureHead,
           running.outputStart > running.promptRow {
            blocks.setHeadLines(measureHead(running.promptRow..<running.outputStart), id: running.id)
        }
        if let selectedBlockID, blocks.block(id: selectedBlockID) == nil { self.selectedBlockID = nil }
        syncActivity()
        onBlocksChanged?()
    }

    private func applyNative(_ stamped: StampedShellEvent, runningBefore: Int?) {
        switch stamped.event {
        case .alternateScreen(let on):
            inAlternateScreen = on
            refreshMode()
        case .mouseTracking(let on):
            mouseTracking = on
            refreshMode()
        case .promptStart:
            atPrompt = false
            sawPrompt = true
            if let runningBefore, let capture = stamped.capture { blocks.setOutput(ranInGrid ? .empty : capture, id: runningBefore) }
            leaveGrid()
        case .promptEnd:
            if let capture = stamped.capture { promptLines = capture.lines }
            atPrompt = blocks.running == nil
        case .commandStart:
            atPrompt = false
            if let running = blocks.running {
                blocks.setPrompt(promptLines, id: running.id)
                runningCommand = running.command
                refreshMode()
            }
        case .commandEnd:
            if let runningBefore, blocks.block(id: runningBefore)?.isRunning == false, let capture = stamped.capture {
                blocks.setOutput(ranInGrid ? .empty : capture, id: runningBefore)
            }
            if let runningBefore, let command = blocks.block(id: runningBefore)?.command, ClearCommand.isClear(command) {
                blocks.replace([])
            }
            leaveGrid()
        default:
            break
        }
    }

    private func leaveGrid() {
        runningCommand = nil
        inAlternateScreen = false
        mouseTracking = false
        ranInGrid = false
        manualMode = nil
        refreshMode()
    }

    public func toggleGrid() {
        guard isNative, phase == .running else { return }
        manualMode = mode.isGrid ? .blocks : .grid(.manual)
        refreshMode()
        onBlocksChanged?()
    }

    private func refreshMode() {
        var next = PaneMode.grid(.plainShell)
        if isNative {
            next = PaneModeDecider.decide(
                altScreen: inAlternateScreen, mouse: mouseTracking, command: runningCommand, allowlist: allowlist)
            if next == .grid(.allowlisted) || next == .grid(.mouseTracking) { ranInGrid = true }
        }
        if isNative, let manualMode { next = manualMode }
        if next != mode { mode = next }
    }

    @discardableResult
    public func submit(_ text: String) -> Bool {
        guard phase == .running, isNative, blocks.running == nil, atPrompt || sawPrompt else { return false }
        atPrompt = false
        engine.write(InputSender.bytes(text: text, bracketedPaste: engine.bracketedPasteMode))
        return true
    }

    public func paste(_ text: String) {
        let bytes = InputSender.pasteBytes(text: text, bracketedPaste: engine.bracketedPasteMode)
        if !bytes.isEmpty { write(bytes) }
    }

    public func sendKeys(_ key: TerminalKey, control: Bool = false) {
        write(KeyEncoder.bytes(key, control: control, applicationCursor: engine.applicationCursorMode))
    }

    private func syncActivity() {
        let current = blocks.activity
        if current != activity { activity = current }
    }

    public func selectBlock(_ id: Int?) {
        guard selectedBlockID != id else { return }
        selectedBlockID = id
        onBlocksChanged?()
    }

    public func trimBlocks(before row: Int) {
        let count = blocks.blocks.count
        blocks.trim(before: row)
        guard blocks.blocks.count != count else { return }
        syncActivity()
        onBlocksChanged?()
    }

    public func replaceBlocks(_ blocks: [TerminalBlock]) {
        self.blocks.replace(blocks)
        if let selectedBlockID, self.blocks.block(id: selectedBlockID) == nil { self.selectedBlockID = nil }
        syncActivity()
        onBlocksChanged?()
    }

    @discardableResult
    public func rerun(_ id: Int) -> Result<BlockRerun.Action, BlockRerun.Refusal> {
        guard let block = blocks.block(id: id) else { return .failure(.empty) }
        let decision = BlockRerun.decide(
            command: block.command, bracketedPaste: engine.bracketedPasteMode, atPrompt: phase == .running && blocks.running == nil)
        if case .success(.type(let bytes)) = decision { write(bytes) }
        return decision
    }

    private static func failureText(_ reason: String) -> String { "Não abriu o shell: \(reason)" }

    private func setDirectory(_ path: String) {
        guard let path = TerminalDirectory.path(fromReport: path), path != directory else { return }
        directory = path
        onDirectory?(path)
    }
}

public enum TerminalSessionName {
    public static func make(title: String, directory: String?, home: String?, shell: TerminalShell) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let directory, !directory.isEmpty {
            if directory == home { return "~" }
            if directory == "/" { return "/" }
            return (directory as NSString).lastPathComponent
        }
        return shell.name
    }
}

public enum ClearCommand {
    public static func isClear(_ command: String) -> Bool {
        guard !command.contains(where: { ";&|\n`$(".contains($0) }) else { return false }
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return false }
        let name = String(first.split(separator: "/").last ?? Substring(first))
        switch name {
        case "clear", "reset": return true
        case "tput": return words.dropFirst().contains { $0 == "clear" || $0 == "reset" }
        default: return false
        }
    }
}
