import AppKit
import SwiftUI
import WispCore

private struct WindowModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the panel content lives in the regular window: no notch band, the window supplies the top inset.
    var windowMode: Bool {
        get { self[WindowModeKey.self] }
        set { self[WindowModeKey.self] = newValue }
    }
}

private struct WindowContentView: View {
    @ObservedObject var controller: ShellController

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            PanelView(controller: controller, media: controller.media, model: controller.conversation)
        }
        .environment(\.windowMode, true)
    }
}

/// A normal window with the same `PanelView` and the same `ShellController`; the app is a regular app while it is open.
private final class WispWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, key == "w" {
            performClose(nil)
            return true
        }
        if flags == [.control, .command], key == "f" {
            toggleFullScreen(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class WispWindowController: NSObject, NSWindowDelegate {
    static let minimumSize = CGSize(width: 900, height: 600)
    static let defaultSize = CGSize(width: 1280, height: 820)

    private weak var shell: ShellController?
    private var window: NSWindow?
    private var quitting = false
    /// Called after the window opens or closes so the shell can fold the panel and refresh the pill.
    var onChange: (() -> Void)?

    init(shell: ShellController) {
        self.shell = shell
    }

    var isOpen: Bool { window != nil }

    func markQuitting() { quitting = true }

    func show() {
        if let window {
            focus(window)
            return
        }
        guard let shell else { return }
        let window = WispWindow(
            contentRect: CGRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Wisp"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.bg)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: WindowContentView(controller: shell))
        window.center()
        window.setFrameAutosaveName("WispWindow")
        self.window = window
        quitting = false
        NSApp.setActivationPolicy(Self.policy(for: ShellSurface.activation(windowOpen: true)))
        AppSettings.shared.setWindowMode(true)
        onChange?()
        focus(window)
    }

    func focus() {
        if let window { focus(window) }
    }

    func close() {
        window?.close()
    }

    func owns(_ event: NSEvent) -> Bool {
        window != nil && event.window === window
    }

    private func focus(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func policy(for activation: ShellSurface.Activation) -> NSApplication.ActivationPolicy {
        switch activation {
        case .regular: .regular
        case .accessory: .accessory
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        let current = AppSettings.shared.settings.windowMode
        AppSettings.shared.setWindowMode(ShellSurface.windowModeAfterClose(current: current, quitting: quitting))
        NSApp.setActivationPolicy(Self.policy(for: ShellSurface.activation(windowOpen: false)))
        onChange?()
    }
}
