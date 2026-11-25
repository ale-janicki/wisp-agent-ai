import Foundation
import Observation

/// One shell in one pty. The engine does the drawing; this holds what the tab needs to show and to start the shell again.
@MainActor @Observable
public final class TerminalSession: Identifiable {
    public enum Phase: Equatable {
        case idle
        case running
        /// The shell ended; nil when a signal ended it.
        case ended(Int32?)
        case failed(String)
    }

    public nonisolated let id: UUID
    public private(set) var phase: Phase = .idle
    /// The last window title a program set (a running `vim` or `claude` sets one); empty when none did.
    public private(set) var title = ""
    /// Where the shell is, as far as it reported (OSC 7) or the system answered.
    public private(set) var directory: String
    public private(set) var engine: any TerminalEngine

    @ObservationIgnored public let shell: TerminalShell
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let integration: ShellIntegration?
    @ObservationIgnored private let integrationEnabled: () -> Bool
    /// The commands of this session, as blocks. The tab draws them over the screen; it is told through `onBlocksChanged`.
    @ObservationIgnored public private(set) var blocks = BlockTracker()
    @ObservationIgnored public private(set) var selectedBlockID: Int?
    /// The shell was started with the hooks, so `blocks` fills in.
    @ObservationIgnored public private(set) var isIntegrated = false
    @ObservationIgnored public var onBlocksChanged: (() -> Void)?
    /// How many lines the screen rows in a range make (a wrapped row continues the one above); set by the app, which holds the screen.
    @ObservationIgnored public var measureHead: ((Range<Int>) -> Int)?
    @ObservationIgnored private let makeEngine: () -> any TerminalEngine
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var size = TerminalSize.standard
    /// Called with every new directory so the workspace can remember the last one.
    @ObservationIgnored public var onDirectory: ((String) -> Void)?

    public init(
        id: UUID = UUID(), shell: TerminalShell, environment: [String: String], directory: String,
        integration: ShellIntegration? = nil, integrationEnabled: @escaping () -> Bool = { true },
        makeEngine: @escaping () -> any TerminalEngine
    ) {
        self.id = id
        self.shell = shell
        self.environment = environment
        self.integration = integration
        self.integrationEnabled = integrationEnabled
        self.directory = directory
        self.makeEngine = makeEngine
        engine = makeEngine()
    }

    public var name: String {
        TerminalSessionName.make(title: title, directory: directory, home: environment["HOME"], shell: shell)
    }

    public var isRunning: Bool { phase == .running }

    public func start(size: TerminalSize = .standard) {
        guard phase == .idle else { return }
        self.size = size
        launch()
    }

    /// A fresh engine and screen in the directory the shell was last in; only after the shell ended or never started.
    public func reopen() {
        switch phase {
        case .ended, .failed: break
        case .idle, .running: return
        }
        engine = makeEngine()
        blocks = BlockTracker()
        selectedBlockID = nil
        launch()
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

    /// Ends the shell for good: its exit is not reported as the shell ending by itself.
    public func close() {
        generation += 1
        refreshDirectory()
        if phase == .running { engine.terminate() }
        phase = .idle
    }

    /// One read from the system, never a poll: the workspace calls it when a session closes, the tab hides or the app quits.
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
            self.onBlocksChanged?()
        }
        // An integrated shell reports its folder in its own marks; a plain OSC 7 any program can print is not taken for it.
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
        let plan = integration?.launch(shell: shell, environment: environment, enabled: integrationEnabled())
            ?? TerminalLaunch(arguments: shell.arguments, execName: shell.loginName, environment: environment, integrated: false)
        isIntegrated = plan.integrated
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
            // The hooks did not go in: no blocks, and the folder may come as a plain OSC 7 again.
            if stamped.event == .declined { isIntegrated = false }
            blocks.apply(stamped.event, anchor: stamped.anchor, at: stamped.date)
        }
        if let directory = blocks.directory { setDirectory(directory) }
        if events.contains(where: { $0.event == .commandStart }), let running = blocks.running, let measureHead,
           running.outputStart > running.promptRow {
            blocks.setHeadLines(measureHead(running.promptRow..<running.outputStart), id: running.id)
        }
        if let selectedBlockID, blocks.block(id: selectedBlockID) == nil { self.selectedBlockID = nil }
        onBlocksChanged?()
    }

    public func selectBlock(_ id: Int?) {
        guard selectedBlockID != id else { return }
        selectedBlockID = id
        onBlocksChanged?()
    }

    /// Rows before `row` left the scrollback.
    public func trimBlocks(before row: Int) {
        let count = blocks.blocks.count
        blocks.trim(before: row)
        if blocks.blocks.count != count { onBlocksChanged?() }
    }

    public func replaceBlocks(_ blocks: [TerminalBlock]) {
        self.blocks.replace(blocks)
        if let selectedBlockID, self.blocks.block(id: selectedBlockID) == nil { self.selectedBlockID = nil }
        onBlocksChanged?()
    }

    /// "Colar de novo" (see `BlockRerun`): a bracketed paste is typed here, at the prompt only, without Enter. A `.copy` is handed
    /// back for the app to put on the clipboard; nothing reaches the shell.
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
    /// What a title in the session strip says: the program's title when one set it, else the folder's name, else the shell.
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
