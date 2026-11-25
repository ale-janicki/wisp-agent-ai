import AppKit
import SwiftUI
import WispCore

/// Holds one pane's engine view while its tab is on screen. The engine's view outlives this container: leaving the tab only
/// detaches it, so nothing draws while it is away and the shell keeps its screen.
final class TerminalHostView: NSView {
    private(set) var engine: SwiftTermEngine?
    private(set) var session: TerminalSession?
    private let overlay = BlockOverlayView(frame: .zero)
    private var focused = false

    /// `focused` takes the keyboard when the pane becomes the focused one or comes on screen as it; otherwise the first responder is
    /// left alone (the sidebar's search keeps it while the rows redraw).
    func show(_ engine: SwiftTermEngine, session: TerminalSession, focused: Bool) {
        if self.engine !== engine { detach() }
        self.engine = engine
        self.session = session
        let view = engine.view
        let attached = view.superview !== self
        if attached {
            view.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        if focused, attached || !self.focused { focusSoon(view) }
        self.focused = focused
        // The overlay is above the screen with the same frame, and takes only the mouse events on a header or border.
        if overlay.superview !== self {
            overlay.frame = bounds
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay, positioned: .above, relativeTo: view)
        }
        overlay.attach(session: session, engine: engine)
    }

    func detach() {
        overlay.detach()
        overlay.removeFromSuperview()
        if let view = engine?.view, view.superview === self { view.removeFromSuperview() }
        engine = nil
        session = nil
        focused = false
    }

    func jumpBlock(previous: Bool) -> Bool { overlay.jump(previous: previous) }

    func copySelectedBlock(_ part: BlockCopy) -> Bool { overlay.copySelected(part) }

    private func focusSoon(_ view: NSView) {
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, view.superview === self, let window = self.window else { return }
            window.makeFirstResponder(view)
        }
    }

    /// Whether the keyboard focus is the terminal or something inside it (its find bar).
    var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        TerminalPaneKeys.handle(event, in: self) || TerminalKeys.handle(event, in: self) || super.performKeyEquivalent(with: event)
    }
}

/// The terminal's own shortcuts. The shell program may not claim these: they belong to the app around it.
@MainActor
enum TerminalKeys {
    static func handle(_ event: NSEvent, in host: TerminalHostView) -> Bool {
        guard event.type == .keyDown, host.hasFocus, let engine = host.engine else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if flags == .command, event.keyCode == 126 || event.keyCode == 125 {
            return host.jumpBlock(previous: event.keyCode == 126)
        }
        // Warp's mapping: ⇧⌘C copies the selected block's command, ⌥⇧⌘C its output.
        if event.charactersIgnoringModifiers?.lowercased() == "c", flags == [.command, .shift] {
            return host.copySelectedBlock(.command)
        }
        if event.charactersIgnoringModifiers?.lowercased() == "c", flags == [.command, .shift, .option] {
            return host.copySelectedBlock(.output)
        }
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let workspace = TerminalStore.shared.workspace
        let view = engine.view
        switch key {
        case "t":
            workspace.openSession()
            return true
        case "w":
            return workspace.closeSelected()
        case "f":
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            view.performFindPanelAction(item)
            return true
        case "c", "v", "a":
            // In the find bar these belong to its text field.
            guard host.window?.firstResponder === view else { return false }
            switch key {
            case "c":
                // Selected text first; with none, the selected block (command and output). Nothing selected copies nothing, and
                // the clipboard stays as it was.
                if view.selectionActive { view.copy(host) } else { _ = host.copySelectedBlock(.commandAndOutput) }
            case "v": view.paste(host)
            default: view.selectAll(host)
            }
            return true
        default:
            return false
        }
    }

    /// Whether the keyboard focus of `window` is a terminal (or its find bar): Esc then belongs to the program in it.
    static func hasFocus(in window: NSWindow?) -> Bool {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if current is TerminalHostView { return true }
            view = current.superview
        }
        return false
    }

    /// ⌘W in the window: while the Terminal tab is up and has a session, it closes the session and never the window.
    static func closeSession(in window: NSWindow) -> Bool {
        guard let host = find(in: window.contentView), host.engine != nil else { return false }
        return TerminalStore.shared.workspace.closeSelected()
    }

    private static func find(in view: NSView?) -> TerminalHostView? {
        guard let view else { return nil }
        if let host = view as? TerminalHostView { return host }
        for child in view.subviews {
            if let host = find(in: child) { return host }
        }
        return nil
    }
}

struct TerminalSurface: NSViewRepresentable {
    let engine: SwiftTermEngine
    let session: TerminalSession
    let fontSize: CGFloat
    var isFocused = true

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        host.wantsLayer = true
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        engine.applyTheme(AppSettings.shared.colors, fontSize: fontSize)
        host.show(engine, session: session, focused: isFocused)
    }

    static func dismantleNSView(_ host: TerminalHostView, coordinator: ()) {
        host.detach()
    }
}
