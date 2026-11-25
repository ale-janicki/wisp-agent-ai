import AppKit
import SwiftUI
import WispCore

final class TerminalHostView: NSView {
    private(set) var engine: SwiftTermEngine?
    private(set) var session: TerminalSession?
    private let overlay = BlockOverlayView(frame: .zero)
    private var pane: TerminalPaneView?
    private var focused = false
    private var clickMonitor: Any?
    var workspace = TerminalStore.shared.workspace

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard window != nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, let session = self.session else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point), self.workspace.selectedID != session.id { self.workspace.select(session.id) }
            return event
        }
    }

    func show(_ engine: SwiftTermEngine, session: TerminalSession, focused: Bool) {
        if self.engine !== engine { detach() }
        self.engine = engine
        self.session = session
        if session.isNative {
            showNative(engine, session: session, focused: focused)
            return
        }
        dropPane()
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
        if overlay.superview !== self {
            overlay.frame = bounds
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay, positioned: .above, relativeTo: view)
        }
        overlay.attach(session: session, engine: engine)
    }

    private func showNative(_ engine: SwiftTermEngine, session: TerminalSession, focused: Bool) {
        if overlay.superview === self {
            overlay.detach()
            overlay.removeFromSuperview()
        }
        let pane = self.pane ?? TerminalPaneView(frame: bounds)
        let attached = engine.view.superview !== pane
        if pane.superview !== self {
            pane.frame = bounds
            pane.autoresizingMask = [.width, .height]
            addSubview(pane)
        }
        self.pane = pane
        pane.attach(engine: engine, session: session)
        if focused, attached || !self.focused { focusSoon(pane) }
        self.focused = focused
    }

    private func dropPane() {
        guard let pane else { return }
        pane.detach()
        pane.removeFromSuperview()
        self.pane = nil
    }

    func detach() {
        dropPane()
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
            if let pane = view as? TerminalPaneView {
                pane.focus()
            } else {
                window.makeFirstResponder(view)
            }
        }
    }

    var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        TerminalPaneKeys.handle(event, in: self) || pane?.performKeyEquivalent(with: event) == true
            || TerminalKeys.handle(event, in: self) || super.performKeyEquivalent(with: event)
    }
}

@MainActor
enum TerminalKeys {
    static func handle(_ event: NSEvent, in host: TerminalHostView) -> Bool {
        guard event.type == .keyDown, host.hasFocus, let engine = host.engine else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if flags == .command, event.keyCode == 126 || event.keyCode == 125 {
            return host.jumpBlock(previous: event.keyCode == 126)
        }
        if event.charactersIgnoringModifiers?.lowercased() == "c", flags == [.command, .shift] {
            return host.copySelectedBlock(.command)
        }
        if event.charactersIgnoringModifiers?.lowercased() == "c", flags == [.command, .shift, .option] {
            return host.copySelectedBlock(.output)
        }
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let workspace = host.workspace
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
            guard host.window?.firstResponder === view else { return false }
            switch key {
            case "c":
                if view.selectionActive { view.copy(host) } else { _ = host.copySelectedBlock(.commandAndOutput) }
            case "v": view.paste(host)
            default: view.selectAll(host)
            }
            return true
        default:
            return false
        }
    }

    static func hasFocus(in window: NSWindow?) -> Bool {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if current is TerminalHostView { return true }
            view = current.superview
        }
        return false
    }

    static func closeSession(in window: NSWindow) -> Bool {
        guard let host = find(in: window.contentView), host.engine != nil else { return false }
        return host.workspace.closeSelected()
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
    var workspace = TerminalStore.shared.workspace

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        host.workspace = workspace
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
