import Foundation

public struct TerminalSize: Equatable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    public static let standard = TerminalSize(columns: 80, rows: 24)
}

/// What draws the screen and owns the pty. The app plugs SwiftTerm in; tests plug in a fake, and a later engine can replace it
/// without touching the session model.
@MainActor
public protocol TerminalEngine: AnyObject {
    /// A batch of output was applied to the screen. It may run on any thread and carries no bytes: the engine draws them itself.
    /// The engine does no per-batch work for it while it is nil.
    var onOutput: (@Sendable () -> Void)? { get set }
    /// The shell never started (the system refused it); the reason, for the person. `onExit` does not follow.
    var onFailure: (@MainActor (String) -> Void)? { get set }
    /// The shell ended: its exit status, or nil when a signal ended it.
    var onExit: (@MainActor (Int32?) -> Void)? { get set }
    /// The shell reported its directory (OSC 7).
    var onDirectory: (@MainActor (String) -> Void)? { get set }
    /// A program set the window title (OSC 0/2).
    var onTitle: (@MainActor (String) -> Void)? { get set }

    /// Marks the shell sent (command start, end, directory...) with where the cursor was at each. Only for an integrated launch.
    var onShellEvents: (@MainActor ([StampedShellEvent]) -> Void)? { get set }

    /// Runs `shell` in `cwd` the way `launch` says (`launch.environment` is the whole environment of the child).
    func start(shell: TerminalShell, launch: TerminalLaunch, cwd: String, size: TerminalSize) throws
    func write(_ bytes: [UInt8])
    /// The program on the terminal turned bracketed paste on (DEC mode 2004), as the terminal itself holds it now.
    var bracketedPasteMode: Bool { get }
    /// Tells the pty its new size; the child gets SIGWINCH.
    func resize(_ size: TerminalSize)
    /// Asks the shell to end. The exit still arrives through `onExit` unless the engine is dropped.
    func terminate()
    /// For quitting: waits, no later than `deadline`, for the child `terminate` signalled to be gone, then kills its process group.
    /// The one place that blocks; a normal close escalates later without waiting.
    func settle(by deadline: Date)
    /// The shell's current directory, read once from the system; nil when it is not running.
    func currentDirectory() -> String?
}

/// A shell event with the cursor position and time it happened.
public struct StampedShellEvent: Equatable, Sendable {
    public let event: ShellEvent
    public let anchor: BlockAnchor
    public let date: Date

    public init(event: ShellEvent, anchor: BlockAnchor, date: Date = Date()) {
        self.event = event
        self.anchor = anchor
        self.date = date
    }
}
