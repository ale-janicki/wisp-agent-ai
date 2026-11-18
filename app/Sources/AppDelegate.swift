import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shell: ShellController?
    private let runtime = RuntimeInstaller()

    func applicationWillTerminate(_ notification: Notification) {
        runtime.cancel()
        AppSettings.shared.flush()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        if let directory = SnapshotRenderer.directory(from: ProcessInfo.processInfo.arguments) {
            Task {
                await SnapshotRenderer.run(into: directory)
                NSApp.terminate(nil)
            }
            return
        }
        #endif
        let shell = ShellController()
        self.shell = shell
        shell.start()
        #if DEBUG
        shell.runDebugArguments()
        #endif
        Task { await runtime.ensure() }
    }
}
