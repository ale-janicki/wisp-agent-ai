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

@MainActor
public protocol TerminalEngine: AnyObject {
    var onOutput: (@Sendable () -> Void)? { get set }
    var onFailure: (@MainActor (String) -> Void)? { get set }
    var onExit: (@MainActor (Int32?) -> Void)? { get set }
    var onDirectory: (@MainActor (String) -> Void)? { get set }
    var onTitle: (@MainActor (String) -> Void)? { get set }

    var onShellEvents: (@MainActor ([StampedShellEvent]) -> Void)? { get set }

    func start(shell: TerminalShell, launch: TerminalLaunch, cwd: String, size: TerminalSize) throws
    func write(_ bytes: [UInt8])
    var bracketedPasteMode: Bool { get }
    var applicationCursorMode: Bool { get }
    func resize(_ size: TerminalSize)
    func terminate()
    func settle(by deadline: Date)
    func currentDirectory() -> String?
}

extension TerminalEngine {
    public var applicationCursorMode: Bool { false }
}

public struct StampedShellEvent: Equatable, Sendable {
    public let event: ShellEvent
    public let anchor: BlockAnchor
    public let date: Date
    public let capture: BlockOutput?

    public init(event: ShellEvent, anchor: BlockAnchor, date: Date = Date(), capture: BlockOutput? = nil) {
        self.event = event
        self.anchor = anchor
        self.date = date
        self.capture = capture
    }
}
