/// Which surface answers when the notch is used: the notch panel, or the regular window when one is open.
public enum ShellSurface {
    public enum PillClick: Equatable, Sendable {
        case openPanel, focusPanel, focusWindow
    }

    public enum Toggle: Equatable, Sendable {
        case openPanel, closePanel, focusWindow
    }

    public enum Activation: Equatable, Sendable {
        case regular, accessory
    }

    public static func pillClick(panelOpen: Bool, windowOpen: Bool) -> PillClick {
        if windowOpen { return .focusWindow }
        return panelOpen ? .focusPanel : .openPanel
    }

    public static func toggle(panelOpen: Bool, windowOpen: Bool) -> Toggle {
        if windowOpen { return .focusWindow }
        return panelOpen ? .closePanel : .openPanel
    }

    /// Resting on the notch never opens the panel over a window.
    public static func allowsHoverOpen(windowOpen: Bool) -> Bool { !windowOpen }

    /// The window needs a Dock icon, ⌘Tab and keyboard focus; without it the app stays out of the Dock.
    public static func activation(windowOpen: Bool) -> Activation { windowOpen ? .regular : .accessory }

    /// A close during quit keeps the flag so the next launch brings the window back; any other close clears it.
    public static func windowModeAfterClose(current: Bool, quitting: Bool) -> Bool { quitting ? current : false }
}
