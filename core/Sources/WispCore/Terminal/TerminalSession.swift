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
    @ObservationIgnored private let makeEngine: () -> any TerminalEngine
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var size = TerminalSize.standard
    /// Called with every new directory so the workspace can remember the last one.
    @ObservationIgnored public var onDirectory: ((String) -> Void)?

    public init(
        id: UUID = UUID(), shell: TerminalShell, environment: [String: String], directory: String,
        makeEngine: @escaping () -> any TerminalEngine
    ) {
        self.id = id
        self.shell = shell
        self.environment = environment
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
        }
        engine.onDirectory = { [weak self] path in
            guard let self, self.generation == mine else { return }
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
        do {
            try engine.start(shell: shell, cwd: directory, env: environment, size: size)
            title = ""
            phase = .running
        } catch {
            phase = .failed(Self.failureText(error.localizedDescription))
        }
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
