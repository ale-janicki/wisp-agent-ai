import AppKit
import WispCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shell: ShellController?
    private var setup: SetupWindowController?
    private let runtime = RuntimeInstaller()
    private var brainColher: BrainColherService?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !QuitFlush.shared.isEmpty else { return .terminateNow }
        Task { @MainActor in
            await QuitFlush.shared.flushAll(timeout: .seconds(3))
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrainModel.shared.flushForQuit()
        runtime.cancel()
        brainColher?.stop()
        shell?.meetings.stopForQuit()
        setup?.session.model?.cancelPolling(blocking: true)
        AppSettings.shared.flush()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        if ArtRenderer.isRequested(ProcessInfo.processInfo.arguments) {
            ArtRenderer.run(ProcessInfo.processInfo.arguments)
            NSApp.terminate(nil)
            return
        }
        #endif
        IdentityMigration.run()
        #if DEBUG
        if let directory = SnapshotRenderer.directory(from: ProcessInfo.processInfo.arguments) {
            Task {
                await SnapshotRenderer.run(into: directory)
                NSApp.terminate(nil)
            }
            return
        }
        if let home = SetupAutorun.homeOverride(from: ProcessInfo.processInfo.arguments) {
            AppSettings.shared.persists = false
            presentSetup(homeOverride: home, existingInstall: false)
            if let controller = setup, SetupAutorun.isRequested(ProcessInfo.processInfo.arguments) {
                Task { await SetupAutorun.run(controller: controller, home: home) }
            }
            Task { await runtime.ensure() }
            return
        }
        if let step = SetupAutorun.forcedStep(from: ProcessInfo.processInfo.arguments) {
            presentSetup(homeOverride: nil, existingInstall: true)
            if let controller = setup { Task { await SetupAutorun.open(step, controller: controller) } }
            Task { await runtime.ensure() }
            return
        }
        #endif
        UpdateModel.shared.start()
        if Self.setupNeeded() {
            presentSetup(homeOverride: nil, existingInstall: Self.profileExists())
        } else {
            startShell()
        }
        Task { await runtime.ensure() }
    }

    func showSetup() {
        presentSetup(homeOverride: nil, existingInstall: true)
    }

    private func presentSetup(homeOverride: URL?, existingInstall: Bool) {
        if let setup {
            setup.show()
            return
        }
        let controller = SetupWindowController(runtime: runtime, homeOverride: homeOverride, existingInstall: existingInstall) { [weak self] in
            guard let self else { return }
            self.setup = nil
            #if DEBUG
            if homeOverride != nil { return }
            #endif
            if let shell = self.shell {
                shell.conversation.reloadProfile()
            } else {
                self.startShell()
            }
        }
        setup = controller
        controller.show()
    }

    private func startShell() {
        let finished = (try? SetupState.load(from: SetupModel.defaultStateURL))?.finishedAt != nil
        LoginItemModel.shared.sync(setupFinished: finished)
        let shell = ShellController()
        self.shell = shell
        if brainColher == nil {
            let layout = RuntimeLayout(bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
            brainColher = BrainColherService(wisp: layout.wisp)
            brainColher?.start()
        }
        UpdateModel.shared.notices = shell.notices
        shell.start()
        shell.meetings.recoverInterrupted()
        #if DEBUG
        shell.runDebugArguments()
        #endif
        #if DEBUG || WISP_PERF
        shell.openPanelFromArguments()
        #endif
    }

    private static func setupNeeded() -> Bool {
        let state = try? SetupState.load(from: SetupModel.defaultStateURL)
        return SetupGate.shouldShowWizard(state: state, profileExists: profileExists())
    }

    private static func profileExists() -> Bool {
        let path = ProfileLoader.defaultURL.path
        let fm = FileManager.default
        return fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
