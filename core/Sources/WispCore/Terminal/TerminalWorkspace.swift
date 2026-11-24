import Foundation
import Observation

/// The sessions of the Terminal tab and which one is showing. One workspace serves the notch panel and the window.
@MainActor @Observable
public final class TerminalWorkspace {
    public private(set) var sessions: [TerminalSession] = []
    public private(set) var selectedID: TerminalSession.ID?

    @ObservationIgnored private let memory: TerminalDirectory.Memory
    @ObservationIgnored private let home: String
    @ObservationIgnored private let makeSession: (_ directory: String) -> TerminalSession
    /// The first session is opened once per launch; closing them all leaves the tab empty until the user asks for one.
    @ObservationIgnored private var openedFirst = false

    public init(memory: TerminalDirectory.Memory, home: String, makeSession: @escaping (_ directory: String) -> TerminalSession) {
        self.memory = memory
        self.home = home
        self.makeSession = makeSession
    }

    public var selected: TerminalSession? { sessions.first { $0.id == selectedID } }

    /// Phase 1 restores no sessions: every launch opens one fresh shell, in the last directory.
    public func openFirstIfNeeded() {
        guard !openedFirst else { return }
        openedFirst = true
        if sessions.isEmpty { openSession() }
    }

    @discardableResult
    public func openSession(size: TerminalSize = .standard) -> TerminalSession {
        openedFirst = true
        let session = makeSession(selected.map { $0.directory } ?? memory.startDirectory(home: home))
        session.onDirectory = { [memory] path in memory.remember(path) }
        sessions.append(session)
        selectedID = session.id
        session.start(size: size)
        return session
    }

    public func select(_ id: TerminalSession.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    public func close(_ id: TerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        session.close()
        memory.remember(session.directory)
        if selectedID == id {
            selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
        }
    }

    /// ⌘W while the terminal has focus: false when there was no session to close, so the window may take the key.
    @discardableResult
    public func closeSelected() -> Bool {
        guard let id = selectedID else { return false }
        close(id)
        return true
    }

    /// Reads each shell's directory once and keeps the selected session's as the one to start in next time.
    public func rememberDirectories() {
        for session in sessions { session.refreshDirectory() }
        if let selected { memory.remember(selected.directory) }
    }

    /// Quitting: every shell is signalled first, then all get up to `grace` together to leave before their process groups are killed.
    public func closeAll(grace: TimeInterval = 0.5) {
        rememberDirectories()
        let engines = sessions.filter(\.isRunning).map(\.engine)
        for session in sessions { session.close() }
        let deadline = Date().addingTimeInterval(grace)
        for engine in engines { engine.settle(by: deadline) }
        sessions.removeAll()
        selectedID = nil
    }
}
