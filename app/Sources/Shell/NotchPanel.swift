import AppKit

final class NotchPanel: NSPanel {
    var allowsKey = false
    var onInactiveMouseDown: (@MainActor () -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = NotchPanel.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
    }

    static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow { onInactiveMouseDown?() }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}
