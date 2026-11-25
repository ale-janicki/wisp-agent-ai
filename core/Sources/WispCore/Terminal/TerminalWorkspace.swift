import Foundation
import Observation

/// The sessions of the Terminal tab and how they are laid out: tabs, each a tree of panes, one pane with the keyboard. One workspace
/// serves the notch panel and the window.
@MainActor @Observable
public final class TerminalWorkspace {
    /// Every open session, in the order they were opened; `layout` says which tab and pane each one is.
    public private(set) var sessions: [TerminalSession] = []
    public private(set) var layout = TerminalLayout()
    /// The tab whose name is being edited in the sidebar (double-click or ⌘⇧R); nil when none is.
    public var renamingTabID: UUID?

    /// A closed tab as it was, with the folder of each pane, for ⌘⇧T.
    private struct ClosedTab {
        let tab: TerminalLayout.Tab
        let index: Int
        let directories: [UUID: String]
    }

    @ObservationIgnored private var closedTabs = [ClosedTab]()
    private static let closedTabLimit = 10

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

    /// The focused pane of the selected tab.
    public var selectedID: TerminalSession.ID? { layout.focusedSession }

    public var selected: TerminalSession? { selectedID.flatMap(session) }

    public func session(_ id: TerminalSession.ID) -> TerminalSession? { sessions.first { $0.id == id } }

    /// Phase 1 restores no sessions: every launch opens one fresh shell, in the last directory.
    public func openFirstIfNeeded() {
        guard !openedFirst else { return }
        openedFirst = true
        if sessions.isEmpty { openSession() }
    }

    /// ⌘T: a new tab with one shell, where the focused one is.
    @discardableResult
    public func openSession(size: TerminalSize = .standard) -> TerminalSession {
        selected?.refreshDirectory()
        let session = launch(in: selected.map { $0.directory } ?? memory.startDirectory(home: home), size: size)
        layout.addTab(session: session.id)
        return session
    }

    /// ⌘D / ⌘⇧D: the focused pane is split and a new shell opens in its folder; false with no pane to split.
    @discardableResult
    public func split(_ axis: TerminalLayout.Axis, size: TerminalSize = .standard) -> Bool {
        guard let focused = selected else { return false }
        focused.refreshDirectory()
        let session = launch(in: focused.directory, size: size)
        layout.split(axis, adding: session.id)
        return true
    }

    /// Gives the keyboard to a session's pane and selects its tab.
    public func select(_ id: TerminalSession.ID) {
        layout.focus(id)
    }

    @discardableResult
    public func selectTab(at index: Int) -> Bool { layout.selectTab(at: index) }

    public func selectTab(_ id: UUID) { layout.selectTab(id) }

    @discardableResult
    public func selectLastTab() -> Bool { layout.selectLastTab() }

    @discardableResult
    public func selectAdjacentTab(_ offset: Int) -> Bool { layout.selectAdjacentTab(offset) }

    public func moveTab(from source: Int, to destination: Int) { layout.moveTab(from: source, to: destination) }

    @discardableResult
    public func moveSelectedTab(_ offset: Int) -> Bool { layout.moveSelectedTab(offset) }

    @discardableResult
    public func moveFocus(_ direction: TerminalLayout.Direction) -> Bool { layout.moveFocus(direction) }

    @discardableResult
    public func focusAdjacentPane(_ offset: Int) -> Bool { layout.focusAdjacentPane(offset) }

    @discardableResult
    public func resizeFocused(_ direction: TerminalLayout.Direction) -> Bool { layout.resizeFocused(direction) }

    /// ⌘⇧R: the sidebar opens the selected tab's name for editing.
    @discardableResult
    public func renameSelectedTab() -> Bool {
        guard let id = layout.selectedTabID else { return false }
        renamingTabID = id
        return true
    }

    @discardableResult
    public func toggleMaximize() -> Bool { layout.toggleMaximize() }

    public func resize(_ path: [Int], to ratio: Double) { layout.resize(path, to: ratio) }

    public func rename(_ tab: UUID, to title: String?) {
        layout.rename(tab, to: title)
        if renamingTabID == tab { renamingTabID = nil }
    }

    /// Ends one pane's shell; its tab goes with the last one, and can come back with ⌘⇧T.
    public func close(_ id: TerminalSession.ID) {
        if let index = layout.tabIndex(containing: id), layout.tabs[index].sessions == [id] { rememberClosed(at: index) }
        end(id)
    }

    /// The × of a tab's row: every pane of it ends.
    public func closeTab(_ id: UUID) {
        guard let index = layout.tabs.firstIndex(where: { $0.id == id }) else { return }
        rememberClosed(at: index)
        for session in layout.tabs[index].sessions { end(session) }
    }

    /// ⌘⇧T: the last closed tab comes back where it was, its panes laid out as they were, each a new shell in the pane's last folder.
    @discardableResult
    public func reopenClosedTab(size: TerminalSize = .standard) -> Bool {
        guard let closed = closedTabs.popLast() else { return false }
        var map = [UUID: UUID]()
        for old in closed.tab.sessions {
            map[old] = launch(in: closed.directories[old] ?? memory.startDirectory(home: home), size: size).id
        }
        layout.insertTab(closed.tab.remapped(map), at: closed.index)
        return true
    }

    private func rememberClosed(at index: Int) {
        let tab = layout.tabs[index]
        var directories = [UUID: String]()
        for id in tab.sessions {
            guard let session = session(id) else { continue }
            session.refreshDirectory()
            directories[id] = session.directory
        }
        closedTabs.append(ClosedTab(tab: tab, index: index, directories: directories))
        if closedTabs.count > Self.closedTabLimit { closedTabs.removeFirst(closedTabs.count - Self.closedTabLimit) }
    }

    private func end(_ id: TerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        session.close()
        memory.remember(session.directory)
        layout.close(id)
        if let renaming = renamingTabID, !layout.tabs.contains(where: { $0.id == renaming }) { renamingTabID = nil }
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
        layout.removeAll()
        closedTabs.removeAll()
        renamingTabID = nil
    }

    private func launch(in directory: String, size: TerminalSize) -> TerminalSession {
        openedFirst = true
        let session = makeSession(directory)
        session.onDirectory = { [memory] path in memory.remember(path) }
        sessions.append(session)
        session.start(size: size)
        return session
    }
}
