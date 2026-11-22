import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class SetupSession {
    let runtime: RuntimeInstaller
    let homeOverride: URL?
    let existingInstall: Bool
    private(set) var model: SetupModel?

    init(runtime: RuntimeInstaller, homeOverride: URL?, existingInstall: Bool) {
        self.runtime = runtime
        self.homeOverride = homeOverride
        self.existingInstall = existingInstall
    }

    /// Called whenever the runtime phase changes; builds the model the first time the runtime is ready.
    func adopt(_ phase: RuntimeInstaller.Phase) {
        guard model == nil, case .ready(let wisp) = phase else { return }
        let model = SetupModel(wisp: wisp, homeOverride: homeOverride, existingInstall: existingInstall)
        self.model = model
        Task { await model.load() }
    }

    func retryRuntime() {
        Task { await runtime.ensure() }
    }
}

@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    let session: SetupSession
    private(set) var window: NSWindow?
    private let onClose: () -> Void

    /// `onClose` runs once when the window goes away, finished or not: the shell starts either way.
    init(runtime: RuntimeInstaller, homeOverride: URL?, existingInstall: Bool, onClose: @escaping () -> Void) {
        session = SetupSession(runtime: runtime, homeOverride: homeOverride, existingInstall: existingInstall)
        self.onClose = onClose
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingView(rootView: SetupView(session: session, finish: { [weak self] in self?.finishAndClose() }))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Configurar o Wisp"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.close()
    }

    private func finishAndClose() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose()
    }
}
