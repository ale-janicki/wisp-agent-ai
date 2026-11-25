import AppKit
import Darwin
import SwiftTerm
import WispCore
import os

@MainActor
final class SwiftTermEngine: NSObject, TerminalEngine {
    let view = WispTerminalView(frame: CGRect(x: 0, y: 0, width: 720, height: 420))

    var onOutput: (@Sendable () -> Void)?
    var onExit: (@MainActor (Int32?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onDirectory: (@MainActor (String) -> Void)?
    var onTitle: (@MainActor (String) -> Void)?
    var onShellEvents: (@MainActor ([StampedShellEvent]) -> Void)?
    var onViewportChange: (() -> Void)?
    private(set) var reflowPending = false
    private var columns = 0
    private let pendingRefresh = OSAllocatedUnfairLock(initialState: false)
    nonisolated private static let minimumRefreshDelay: UInt64 = 30_000_000
    nonisolated private static let maximumRefreshDelay: UInt64 = 300_000_000
    private let lastTickCost = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    nonisolated static let scrollback = 100_000
    nonisolated static let maxLiveRows = 500

    private var themeApplied: (colors: ThemeColors, fontSize: CGFloat)?
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

    var applicationCursorMode: Bool {
        view.terminalContentSnapshot(region: .rows(0..<0), buffer: .active)?.inputState.applicationCursor ?? false
    }

    var cursorColumn: Int {
        view.terminalContentSnapshot(region: .rows(0..<0), buffer: .normal)?.cursorColumn ?? 0
    }

    func liveOutput(from row: Int) -> BlockOutput {
        let started = TerminalPerf.now()
        defer {
            let spent = TerminalPerf.now() - started
            TerminalPerf.record { $0.liveNs += spent; $0.liveTicks += 1 }
        }
        guard let snapshot = view.terminalContentSnapshot(region: .rows(0..<0), buffer: .normal) else { return .empty }
        let end = snapshot.cursorRow + 1
        let start = min(max(row, end - Self.maxLiveRows), end)
        let output = SwiftTermStyle.capture(view, rows: start..<end)
        return BlockOutput(lines: output.lines, droppedLines: output.droppedLines + max(0, start - row))
    }

    func rows(_ range: Range<Int>) -> [ScreenRow] { view.screenRows(range) }

    nonisolated static func allRows(of view: WispTerminalView) -> [ScreenRow] {
        guard let snapshot = view.terminalContentSnapshot(region: .all, buffer: .normal) else { return [] }
        return snapshot.rows.map { ScreenRow(row: $0.absoluteRow, text: $0.text, isWrapped: $0.isWrapped) }
    }

    func reflowHandled() { reflowPending = false }

    func scroll(toRow row: Int) {
        guard let viewport = view.viewport() else { return }
        view.scrollTo(row: max(0, row - viewport.firstRetained))
    }

    nonisolated private func outputArrived() {
        let first = pendingRefresh.withLock { pending -> Bool in
            defer { pending = true }
            return !pending
        }
        guard first else { return }
        let delay = min(max(lastTickCost.withLock { $0 } * 4, Self.minimumRefreshDelay), Self.maximumRefreshDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in
            MainActor.assumeIsolated { self?.viewportMayHaveChanged() }
        }
    }

    private func viewportMayHaveChanged() {
        pendingRefresh.withLock { $0 = false }
        let started = TerminalPerf.now()
        onViewportChange?()
        let spent = TerminalPerf.now() - started
        lastTickCost.withLock { $0 = spent }
        TerminalPerf.record { $0.tickNs += spent; $0.ticks += 1 }
    }

    private func terminated(_ code: Int32?) {
        killTask?.cancel()
        view.programStatusProcessExited()
        view.feed(text: "\r\n\u{1B}[2m[processo encerrado]\u{1B}[0m\r\n")
        onExit?(code)
    }

    func applyTheme(_ colors: ThemeColors, fontSize: CGFloat) {
        if let themeApplied, themeApplied.colors == colors, themeApplied.fontSize == fontSize { return }
        themeApplied = (colors, fontSize)
        TerminalTheme.apply(to: view, colors: colors, fontSize: fontSize)
    }

    // MARK: TerminalEngine

    func start(shell: TerminalShell, launch: TerminalLaunch, cwd: String, size: TerminalSize) throws {
        if launch.nativeBlocks { view.changeScrollback(Self.scrollback) }
        view.bridge.configure(
            nonce: launch.integrated ? launch.markNonce : nil, native: launch.nativeBlocks,
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
