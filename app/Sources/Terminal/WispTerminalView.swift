import AppKit
import Darwin
import SwiftTerm
import WispCore
import os

struct TerminalViewport: Equatable {
    var top: Int
    var rows: Int
    var columns: Int
    var firstRetained: Int
    var liveTop: Int
    var cursorRow: Int
    var cellHeight: CGFloat
    var alternateScreen: Bool
}

final class PTYBridge: LocalProcessDelegate, @unchecked Sendable {
    private struct Shared {
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        var onOutput: (@Sendable () -> Void)?
        var onEvents: (@Sendable ([StampedShellEvent]) -> Void)?
        var nonce: String?
        var native = false
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private weak var view: TerminalView?
    var onTerminated: (@MainActor (Int32?) -> Void)?
    var onFailed: (@MainActor (LocalProcessError) -> Void)?

    private var stream: ShellStream?
    private var promptTop: Int?
    private var outputTop: Int?

    init(view: TerminalView) {
        self.view = view
    }

    func configure(nonce: String?, native: Bool, onEvents: (@Sendable ([StampedShellEvent]) -> Void)?, onOutput: (@Sendable () -> Void)?) {
        shared.withLock {
            $0.nonce = nonce
            $0.native = nonce != nil && native
            $0.onEvents = onEvents
            $0.onOutput = onOutput
        }
    }

    func setOutputHandler(_ handler: (@Sendable () -> Void)?) {
        shared.withLock { $0.onOutput = handler }
    }

    func updateWindowSize(_ size: winsize) {
        shared.withLock { $0.size = size }
    }

    // MARK: LocalProcessDelegate

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        Task { @MainActor [onTerminated] in onTerminated?(exitCode) }
    }

    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        Task { @MainActor [onFailed] in onFailed?(error) }
    }

    func getWindowSize() -> winsize {
        shared.withLock { $0.size }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        guard let view else { return }
        let state = shared.withLock { ($0.nonce, $0.onEvents, $0.onOutput, $0.native) }
        let started = TerminalPerf.now()
        defer {
            let spent = TerminalPerf.now() - started
            TerminalPerf.record { $0.readNs += spent; $0.reads += 1 }
            state.2?()
        }
        guard let nonce = state.0 else {
            view.feed(byteArray: slice)
            return
        }
        var stream = self.stream ?? ShellStream(nonce: nonce, nativeBlocks: state.3)
        let cut = stream.cut(slice)
        self.stream = stream
        let bytes = cut.bytes
        var stamped = [StampedShellEvent]()
        for piece in cut.pieces {
            switch piece {
            case .bytes(let range):
                view.feed(byteArray: bytes[(bytes.startIndex + range.lowerBound)..<(bytes.startIndex + range.upperBound)])
            case .headerRow:
                view.feed(text: Self.anchor(view).column > 0 ? "\r\n\r\n" : "\r\n")
            case .resetGrid:
                view.feed(text: "\u{1B}[H\u{1B}[2J\u{1B}[3J")
            case .event(let event):
                let anchor = Self.anchor(view)
                let capture = state.3 ? capture(at: event, anchor: anchor, view: view) : nil
                stamped.append(StampedShellEvent(event: event, anchor: anchor, date: Date(), capture: capture))
            }
        }
        if !stamped.isEmpty { state.1?(stamped) }
    }

    private func capture(at event: ShellEvent, anchor: BlockAnchor, view: TerminalView) -> BlockOutput? {
        let started = TerminalPerf.now()
        defer {
            let spent = TerminalPerf.now() - started
            TerminalPerf.record { $0.captureNs += spent; $0.captures += 1 }
        }
        let end = anchor.column > 0 ? anchor.row + 1 : anchor.row
        switch event {
        case .promptStart:
            promptTop = end
            guard let top = outputTop else { return nil }
            outputTop = nil
            return SwiftTermStyle.capture(view, rows: top..<max(top, end))
        case .promptEnd:
            guard let top = promptTop else { return nil }
            promptTop = nil
            return SwiftTermStyle.capture(view, rows: max(top, anchor.row - 49)..<(anchor.row + 1))
        case .commandStart:
            outputTop = end
            return nil
        case .commandEnd:
            guard let top = outputTop else { return nil }
            outputTop = nil
            return SwiftTermStyle.capture(view, rows: top..<max(top, end))
        default:
            return nil
        }
    }

    private static func anchor(_ view: TerminalView) -> BlockAnchor {
        guard let snapshot = view.terminalContentSnapshot(region: .rows(0..<0), buffer: .normal) else { return BlockAnchor(row: 0, column: 0) }
        return BlockAnchor(row: snapshot.cursorRow, column: snapshot.cursorColumn, liveTop: snapshot.liveTopRow)
    }
}

@MainActor
final class WispTerminalView: TerminalView, TerminalViewDelegate {
    private(set) var process: LocalProcess!
    private(set) var bridge: PTYBridge!

    var onTitle: ((String) -> Void)?
    var onDirectory: ((String?) -> Void)?
    var onScrolled: (() -> Void)?
    var onResized: ((_ columns: Int, _ rows: Int) -> Void)?
    var copyOnSelect = true
    private var selectionBeforePress: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        terminalDelegate = self
        resolvesLinksAgainstShellDirectory = true
        let bridge = PTYBridge(view: self)
        self.bridge = bridge
        process = LocalProcess(delegate: bridge, dispatchQueue: .main, directDelivery: true)
        bridge.updateWindowSize(windowSize())
    }

    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        selectionBeforePress = selectionActive ? getSelection() : nil
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard copyOnSelect, selectionActive, let text = getSelection(), !text.isEmpty, text != selectionBeforePress else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func windowSize() -> winsize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let dimensions = terminalDimensions
        let optimal = dimensions.rows > 0 ? getOptimalFrameSize() : .zero
        let width = dimensions.cols > 0 ? (optimal.width / CGFloat(dimensions.cols)) : 0
        let height = dimensions.rows > 0 ? (optimal.height / CGFloat(dimensions.rows)) : 0
        return winsize(
            ws_row: UInt16(clamping: dimensions.rows), ws_col: UInt16(clamping: dimensions.cols),
            ws_xpixel: UInt16(clamping: Int(width * CGFloat(dimensions.cols) * scale)),
            ws_ypixel: UInt16(clamping: Int(height * CGFloat(dimensions.rows) * scale)))
    }

    func startProcess(executable: String, args: [String], environment: [String], execName: String, currentDirectory: String) {
        bridge.updateWindowSize(windowSize())
        process.startProcess(
            executable: executable, args: args, environment: environment, execName: execName, currentDirectory: currentDirectory)
    }

    func viewport() -> TerminalViewport? {
        guard let snapshot = terminalContentSnapshot(region: .rows(0..<0), buffer: .active) else { return nil }
        let rows = snapshot.inputState.dimensions.rows
        guard rows > 0 else { return nil }
        let first = snapshot.capturedRange.lowerBound
        let span = max(0, snapshot.liveTopRow - first)
        let top = first + Int((scrollPosition * Double(span)).rounded())
        return TerminalViewport(
            top: top, rows: rows, columns: snapshot.inputState.dimensions.cols, firstRetained: first, liveTop: snapshot.liveTopRow,
            cursorRow: snapshot.cursorRow, cellHeight: getOptimalFrameSize().height / CGFloat(rows),
            alternateScreen: snapshot.inputState.isAlternateBuffer)
    }

    nonisolated func screenRows(_ range: Range<Int>) -> [ScreenRow] {
        guard let snapshot = terminalContentSnapshot(region: .rows(range), buffer: .normal) else { return [] }
        return snapshot.rows.map { ScreenRow(row: $0.absoluteRow, text: $0.text, isWrapped: $0.isWrapped) }
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        var size = windowSize()
        bridge.updateWindowSize(size)
        _ = process.updateWindowSize(&size)
        onResized?(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        onDirectory?(directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        onScrolled?()
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }

    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }

    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { nil }

    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { nil }

    func kittyClipboardWrite(
        source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent
    ) -> KittyClipboardWriteResult { .unsupported }

    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }
}
