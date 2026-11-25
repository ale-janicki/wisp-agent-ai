import AppKit
import WispCore

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

    static func handle(_ event: NSEvent, in host: TerminalHostView) -> Bool {
        guard event.type == .keyDown, host.hasFocus, !isFieldEditor(host.window?.firstResponder), let session = host.session
        else { return false }
        let workspace = host.workspace
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

    static func hoverMayMoveFocus(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return true }
        if responder === window || responder is WispTerminalView || responder is InputEditorView || responder is BlockOutputTextView
            || responder is BlockListView { return true }
        guard !isFieldEditor(responder) else { return false }
        var view = (responder as? NSView)?.superview
        while let current = view {
            if current is TerminalPaneView { return true }
            view = current.superview
        }
        return false
    }

    private static func isFieldEditor(_ responder: NSResponder?) -> Bool {
        (responder as? NSTextView)?.isFieldEditor == true
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
