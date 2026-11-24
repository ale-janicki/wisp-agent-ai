import AppKit
import Darwin
import SwiftTerm
import WispCore

/// SwiftTerm behind `TerminalEngine`: `LocalProcessTerminalView` forks the shell on a pty, parses its output and draws it.
@MainActor
final class SwiftTermEngine: NSObject, TerminalEngine, LocalProcessTerminalViewDelegate {
    let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 720, height: 420))

    var onOutput: (@Sendable () -> Void)? {
        didSet { view.setProcessOutputHandler(onOutput) }
    }
    var onExit: (@MainActor (Int32?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onDirectory: (@MainActor (String) -> Void)?
    var onTitle: (@MainActor (String) -> Void)?

    private var themeApplied: (colors: ThemeColors, fontSize: CGFloat)?
    /// The shell this engine started, with its start time: a pid that ended and was reused never matches.
    private var child: Child?
    private var killTask: Task<Void, Never>?
    private static let killDelay: Duration = .seconds(3)

    override init() {
        super.init()
        view.processDelegate = self
    }

    /// Theme and font are applied again only when one of them changed: installing a palette repaints the whole screen.
    func applyTheme(_ colors: ThemeColors, fontSize: CGFloat) {
        if let themeApplied, themeApplied.colors == colors, themeApplied.fontSize == fontSize { return }
        themeApplied = (colors, fontSize)
        TerminalTheme.apply(to: view, colors: colors, fontSize: fontSize)
    }

    // MARK: TerminalEngine

    /// The view's own layout decides the columns and rows the shell starts with; `size` is not needed here.
    func start(shell: TerminalShell, cwd: String, env: [String: String], size: TerminalSize) throws {
        view.startProcess(
            executable: shell.path, args: shell.arguments, environment: TerminalEnvironment.lines(env),
            execName: shell.loginName, currentDirectory: cwd)
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

    // MARK: LocalProcessTerminalViewDelegate

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        killTask?.cancel()
        view.feed(text: "\r\n\u{1B}[2m[processo encerrado]\u{1B}[0m\r\n")
        onExit?(exitCode)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        onFailure?(String(describing: error))
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let path = TerminalDirectory.path(fromReport: directory) else { return }
        onDirectory?(path)
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitle?(title)
    }

    /// The pty follows the view's size by itself (SIGWINCH goes out through `LocalProcessTerminalView`).
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
}
