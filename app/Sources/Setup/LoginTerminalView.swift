import AppKit
import Darwin
import Observation
import SwiftTerm
import SwiftUI
import WispCore

/// Runs the user's own `claude` in a pty for the Login step and watches `claude_login` until she is in.
/// Wisp never touches the login itself: she types `/login` in the terminal (D1).
@MainActor @Observable
final class LoginTerminalSession: LocalProcessTerminalViewDelegate {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case loggedIn
        /// The process ended (or never started) before the login showed up.
        case ended(String)
    }

    private(set) var phase: Phase = .idle
    /// Replaced on every start so "abrir de novo" begins a clean terminal.
    private(set) var terminalView: LocalProcessTerminalView?

    @ObservationIgnored private weak var model: SetupModel?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var exitTask: Task<Void, Never>?
    @ObservationIgnored private var killTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var lastLookTask: Task<Void, Never>?
    /// The last key she pressed in the terminal window, so `/exit` is never typed over her own typing.
    @ObservationIgnored private var lastKeystroke = Date.distantPast
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var launchedAt = Date.distantPast
    /// The process this session started and has not yet seen end; only these pids are ever signalled.
    @ObservationIgnored private var childPid: pid_t = 0
    @ObservationIgnored private var stopping = false

    private static let pollInterval: Duration = .seconds(2)
    private static let quietBeforeExit: TimeInterval = 1.5
    private static let exitGrace: TimeInterval = 10
    private static let killDelay: Duration = .seconds(3)
    private static let trustWindow: TimeInterval = 10
    private static let trustHint = "Se o Claude perguntar se confia nesta pasta, escolha Sim (Yes)"
    /// Never handed to her `claude`: they would point it at another account, another config or a parent session.
    private static func isInherited(_ key: String) -> Bool {
        key == "ANTHROPIC_API_KEY" || key == "CLAUDE_CONFIG_DIR" || key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_")
    }

    // MARK: Lifecycle

    func start(model: SetupModel) {
        guard phase == .idle || isEnded else { return }
        self.model = model
        stopping = false
        phase = .starting
        let home = model.home
        lastLookTask?.cancel()
        startTask = Task { [weak self] in
            // Already in: nothing to type, so no claude is started at all.
            if await model.claudeLoggedIn() == true {
                guard let self, !Task.isCancelled, !self.stopping else { return }
                self.phase = .loggedIn
                model.markDone(.login)
                return
            }
            // `command -v claude` and the login-shell PATH spawn a shell, so they stay off the main actor.
            let resolved = await Task.detached(priority: .userInitiated) { () -> (URL, String?)? in
                guard let url = try? ClaudeLocator.resolve(configured: nil, home: home.path) else { return nil }
                return (url, ClaudeLocator.cachedLoginShellPATH)
            }.value
            guard let self, !Task.isCancelled, !self.stopping else { return }
            guard let (claude, path) = resolved else {
                self.phase = .ended("Não encontrei o Claude neste Mac. Volte ao passo \"O seu Mac\" para instalar.")
                return
            }
            self.launch(claude: claude, path: path, home: home)
        }
    }

    /// The step was left, the window closed or the app is quitting: poll and child both end.
    /// `blocking` waits for the child inside the call (quit cannot wait for a later task).
    func stop(blocking: Bool = false) {
        stopping = true
        startTask?.cancel()
        pollTask?.cancel()
        exitTask?.cancel()
        lastLookTask?.cancel()
        removeKeyMonitor()
        startTask = nil
        pollTask = nil
        exitTask = nil
        lastLookTask = nil
        endChild(blocking: blocking)
        if phase != .loggedIn { phase = .idle }
    }

    private var isEnded: Bool {
        if case .ended = phase { return true }
        return false
    }

    private func launch(claude: URL, path: String?, home: URL) {
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 340))
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(white: 0.07, alpha: 1)
        view.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        var environment = ProcessInfo.processInfo.environment.filter { !Self.isInherited($0.key) }
        if let path { environment["PATH"] = path }
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = "pt_BR.UTF-8"
        environment["HOME"] = home.path
        terminalView = view
        view.startProcess(
            executable: claude.path, args: [], environment: environment.map { "\($0.key)=\($0.value)" },
            execName: nil, currentDirectory: home.path)
        childPid = view.process.shellPid
        launchedAt = Date()
        lastKeystroke = .distantPast
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
            if let self, let view, event.window != nil, event.window === view.window { self.lastKeystroke = Date() }
            return event
        }
        phase = .running
        startPolling()
    }

    // MARK: Watching the login

    /// One poll at a time: the loop awaits each check before sleeping again.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self, let model = self.model, self.phase == .running else { return }
                if await model.claudeLoggedIn() == true, !Task.isCancelled {
                    self.loginDetected(model)
                    return
                }
            }
        }
    }

    private func loginDetected(_ model: SetupModel) {
        phase = .loggedIn
        model.markDone(.login)
        exitTask = Task { [weak self] in
            // `/exit` only once she has been quiet for a moment; then a normal exit gets its time before any signal.
            while !Task.isCancelled, let self, Date().timeIntervalSince(self.lastKeystroke) < Self.quietBeforeExit {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, let self else { return }
            self.terminalView?.send(txt: "/exit\r")
            let deadline = Date().addingTimeInterval(Self.exitGrace)
            while !Task.isCancelled, self.terminalView?.process.running == true, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            self.endChild(blocking: false)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: Ending the child

    /// True only while `pid` is still a child of this app: a pid that ended and was reused is never signalled.
    nonisolated private static func isOurChild(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size == Int32(MemoryLayout<proc_bsdinfo>.size) && info.pbi_ppid == UInt32(getpid())
    }

    /// SIGTERM to the child's whole process group (forkpty makes it the group leader), then SIGKILL after 3 s
    /// if it is still ours. The kill task holds the pid value, not the view, so it still fires after the view is freed.
    private func endChild(blocking: Bool) {
        let pid = childPid
        guard pid > 0, Self.isOurChild(pid) else { return }
        terminalView?.process.terminate()
        killpg(pid, SIGTERM)
        if blocking {
            let deadline = Date().addingTimeInterval(3)
            while Self.isOurChild(pid), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if Self.isOurChild(pid) { killpg(pid, SIGKILL) }
            return
        }
        killTask?.cancel()
        killTask = Task {
            try? await Task.sleep(for: Self.killDelay)
            if Self.isOurChild(pid) { killpg(pid, SIGKILL) }
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === terminalView else { return }
        childPid = 0
        removeKeyMonitor()
        guard !stopping, phase == .running else { return }
        pollTask?.cancel()
        let early = Date().timeIntervalSince(launchedAt) < Self.trustWindow
        phase = .ended(early
            ? "O Claude foi fechado antes de você entrar. \(Self.trustHint)."
            : "O Claude foi fechado antes de você entrar.")
        // One last look: she may have logged in and then quit by hand.
        guard let model else { return }
        lastLookTask = Task { [weak self] in
            if await model.claudeLoggedIn() == true, let self, self.isEnded, !self.stopping {
                self.phase = .loggedIn
                model.markDone(.login)
            }
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// The terminal itself, hosted in a container so a new terminal can replace the one that ended.
struct LoginTerminalView: NSViewRepresentable {
    /// A different terminal (after "abrir de novo") is a different value, so SwiftUI calls `updateNSView` again.
    let terminal: LocalProcessTerminalView?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let terminal, terminal.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        container.window?.makeFirstResponder(terminal)
    }
}

/// The Login step's body: the hint, the terminal and what happened to it. The session starts and stops with
/// `SetupModel.current`, not with this view, which SwiftUI may rebuild at any time.
struct LoginStepView: View {
    let model: SetupModel

    var body: some View {
        let session = model.loginTerminal
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Digite /login e entre com a sua conta da Claude")
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
            Text("Se o Claude perguntar se confia nesta pasta, escolha Sim (Yes)")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            LoginTerminalView(terminal: session.terminalView)
                .frame(height: 340)
            switch session.phase {
            case .loggedIn:
                Label("Você entrou no Claude.", systemImage: "checkmark")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.ok)
            case .ended(let sentence):
                Text(sentence)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.busy)
                Button("abrir de novo") { session.start(model: model) }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            case .idle, .starting, .running:
                EmptyView()
            }
        }
    }
}
