import AppKit
import WispCore

/// The tab and pane shortcuts, in Warp's map. Asked before `TerminalKeys`, and only by the pane that holds the keyboard, so they never
/// fire from another Wisp tab; ⌘T, ⌘W, find, copy and the block keys stay with `TerminalKeys`.
@MainActor
enum TerminalPaneKeys {
    private enum KeyCode {
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let tab: UInt16 = 48
    }

    /// Only when the terminal screen itself has the keyboard: with the find bar focused these keys belong to its text field.
    static func handle(_ event: NSEvent, in host: TerminalHostView) -> Bool {
        guard event.type == .keyDown, let view = host.engine?.view, host.window?.firstResponder === view,
              let session = host.session else { return false }
        let workspace = TerminalStore.shared.workspace
        // The keyboard is the truth: a click moved it into this pane even if no hover told the workspace yet.
        if workspace.selectedID != session.id { workspace.select(session.id) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let code = event.keyCode
        let bracket = TerminalShortcutKey.bracket(characters: event.charactersIgnoringModifiers, keyCode: code)

        switch flags {
        case [.command, .option]:
            guard let direction = direction(code) else { return false }
            workspace.moveFocus(direction)
            return true
        case [.control, .command]:
            guard let direction = direction(code) else { return false }
            workspace.resizeFocused(direction)
            return true
        case [.control, .shift]:
            if code == KeyCode.tab {
                workspace.selectAdjacentTab(-1)
            } else if code == KeyCode.left || code == KeyCode.right {
                workspace.moveSelectedTab(code == KeyCode.left ? -1 : 1)
            } else {
                return false
            }
            return true
        case [.control]:
            guard code == KeyCode.tab else { return false }
            workspace.selectAdjacentTab(1)
            return true
        case [.command, .shift]:
            if code == KeyCode.returnKey || code == KeyCode.enter {
                workspace.toggleMaximize()
                return true
            }
            if let bracket {
                workspace.selectAdjacentTab(bracket)
                return true
            }
            switch key {
            case "d": return workspace.split(.vertical)
            case "t":
                workspace.reopenClosedTab()
                return true
            case "r": return workspace.renameSelectedTab()
            default: return false
            }
        case [.command]:
            if let bracket {
                workspace.focusAdjacentPane(bracket)
                return true
            }
            if key == "d" { return workspace.split(.horizontal) }
            guard let key, let digit = Int(key), (1...9).contains(digit) else { return false }
            if digit == 9 { workspace.selectLastTab() } else { workspace.selectTab(at: digit - 1) }
            return true
        default:
            return false
        }
    }

    /// Whether moving the focus by hover may take the keyboard: only from a terminal screen or from nothing, never from a text
    /// field (the sidebar search, a tab's rename, a find bar).
    static func hoverMayMoveFocus(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return true }
        return responder is WispTerminalView || responder === window
    }

    private static func direction(_ code: UInt16) -> TerminalLayout.Direction? {
        switch code {
        case KeyCode.left: .left
        case KeyCode.right: .right
        case KeyCode.up: .up
        case KeyCode.down: .down
        default: nil
        }
    }
}
