import AppKit
import Darwin
import SwiftTerm
import WispCore
import os

/// SwiftTerm behind `TerminalEngine`: `WispTerminalView` forks the shell on a pty, scans its output for the shell integration's
/// marks, parses it and draws it.
@MainActor
final class SwiftTermEngine: NSObject, TerminalEngine {
    let view = WispTerminalView(frame: CGRect(x: 0, y: 0, width: 720, height: 420))

    var onOutput: (@Sendable () -> Void)?
    var onExit: (@MainActor (Int32?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onDirectory: (@MainActor (String) -> Void)?
    var onTitle: (@MainActor (String) -> Void)?
    var onShellEvents: (@MainActor ([StampedShellEvent]) -> Void)?
    /// The screen moved or changed (scroll, resize, output): coalesced, never polled.
    var onViewportChange: (() -> Void)?
    /// The width changed since the blocks were last placed: the rows were reflowed, so the blocks have to be found again.
    private(set) var reflowPending = false
    private var columns = 0
    private let pendingRefresh = OSAllocatedUnfairLock(initialState: false)
    nonisolated private static let refreshDelay: DispatchTimeInterval = .milliseconds(30)

    private var themeApplied: (colors: ThemeColors, fontSize: CGFloat)?
    /// The shell this engine started, with its start time: a pid that ended and was reused never matches.
    private var child: Child?
    private var killTask: Task<Void, Never>?
    private static let killDelay: Duration = .seconds(3)

    override init() {
        super.init()
        view.bridge.onTerminated = { [weak self] code in self?.terminated(code) }
        view.bridge.onFailed = { [weak self] error in self?.onFailure?(String(describing: error)) }
        view.onTitle = { [weak self] title in self?.onTitle?(title) }
        view.onDirectory = { [weak self] directory in
            guard let path = TerminalDirectory.path(fromReport: directory) else { return }
            self?.onDirectory?(path)
        }
        view.onScrolled = { [weak self] in self?.viewportMayHaveChanged() }
        view.onResized = { [weak self] columns, _ in
            guard let self else { return }
            if self.columns != 0, self.columns != columns { self.reflowPending = true }
            self.columns = columns
            self.viewportMayHaveChanged()
        }
    }

    // MARK: Screen for the blocks

    func viewport() -> TerminalViewport? { view.viewport() }

    var bracketedPasteMode: Bool {
        view.terminalContentSnapshot(region: .rows(0..<0), buffer: .active)?.inputState.bracketedPasteMode ?? false
    }

    func rows(_ range: Range<Int>) -> [ScreenRow] { view.screenRows(range) }

    /// Every row the terminal holds; for finding the blocks again after a reflow. Safe off the main thread.
    nonisolated static func allRows(of view: WispTerminalView) -> [ScreenRow] {
        guard let snapshot = view.terminalContentSnapshot(region: .all, buffer: .normal) else { return [] }
        return snapshot.rows.map { ScreenRow(row: $0.absoluteRow, text: $0.text, isWrapped: $0.isWrapped) }
    }

    func reflowHandled() { reflowPending = false }

    /// Scrolls so `row` (scroll-invariant) is the first on screen.
    func scroll(toRow row: Int) {
        guard let viewport = view.viewport() else { return }
        view.scrollTo(row: max(0, row - viewport.firstRetained))
    }

    /// Output, scroll and resize all end here: at most one notification per `refreshDelay`.
    nonisolated private func outputArrived() {
        let first = pendingRefresh.withLock { pending -> Bool in
            defer { pending = true }
            return !pending
        }
        guard first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshDelay) { [weak self] in
            MainActor.assumeIsolated { self?.viewportMayHaveChanged() }
        }
    }

    private func viewportMayHaveChanged() {
        pendingRefresh.withLock { $0 = false }
        onViewportChange?()
    }

    private func terminated(_ code: Int32?) {
        killTask?.cancel()
        view.programStatusProcessExited()
        view.feed(text: "\r\n\u{1B}[2m[processo encerrado]\u{1B}[0m\r\n")
        onExit?(code)
    }

    /// Theme and font are applied again only when one of them changed: installing a palette repaints the whole screen.
    func applyTheme(_ colors: ThemeColors, fontSize: CGFloat) {
        if let themeApplied, themeApplied.colors == colors, themeApplied.fontSize == fontSize { return }
        themeApplied = (colors, fontSize)
        TerminalTheme.apply(to: view, colors: colors, fontSize: fontSize)
    }

    // MARK: TerminalEngine

    /// The view's own layout decides the columns and rows the shell starts with; `size` is not needed here.
    func start(shell: TerminalShell, launch: TerminalLaunch, cwd: String, size: TerminalSize) throws {
        view.bridge.configure(
            nonce: launch.integrated ? launch.markNonce : nil,
            onEvents: { @Sendable [weak self] events in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onShellEvents?(events) } }
            },
            onOutput: { @Sendable [weak self] in self?.outputArrived() })
        view.startProcess(
            executable: shell.path, args: launch.arguments, environment: TerminalEnvironment.lines(launch.environment),
            execName: launch.execName, currentDirectory: cwd)
        child = Child.capture(view.process.shellPid)
    }

    func write(_ bytes: [UInt8]) {
        view.send(source: view, data: bytes[...])
    }

    func resize(_ size: TerminalSize) {
        var window = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = view.process.updateWindowSize(&window)
    }

    /// SIGHUP to the shell's process group (an interactive shell ignores SIGTERM and leaves on SIGHUP), then SIGKILL once, three
    /// seconds later, if that same child is still ours and alive.
    func terminate() {
        guard let child, child.isAlive else { return }
        killpg(child.pid, SIGHUP)
        view.process.terminate()
        killTask?.cancel()
        killTask = Task {
            try? await Task.sleep(for: Self.killDelay)
            if !Task.isCancelled, child.isAlive { killpg(child.pid, SIGKILL) }
        }
    }

    /// Quit: the app is about to exit and a later task would never run, so this waits (10 ms steps, bounded by `deadline`).
    func settle(by deadline: Date) {
        killTask?.cancel()
        guard let child else { return }
        while child.isAlive, Date() < deadline { usleep(10_000) }
        if child.isAlive { killpg(child.pid, SIGKILL) }
    }

    func currentDirectory() -> String? {
        guard view.process.running, let child, child.isAlive else { return nil }
        return TerminalDirectory.ofProcess(child.pid)
    }

    /// A child of this app, named by pid and start time. `isAlive` is false once it ended (a zombie waiting to be reaped counts
    /// as ended) and for a pid that was reused by another process.
    private struct Child: Sendable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64

        static func capture(_ pid: pid_t) -> Child? {
            guard let info = info(pid) else { return nil }
            return Child(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
        }

        var isAlive: Bool {
            guard pid > 0, let info = Self.info(pid) else { return false }
            return info.pbi_ppid == UInt32(getpid()) && info.pbi_status != UInt32(SZOMB)
                && info.pbi_start_tvsec == startSeconds && info.pbi_start_tvusec == startMicroseconds
        }

        private static func info(_ pid: pid_t) -> proc_bsdinfo? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
        }
    }
}
