import AppKit
import Foundation
import Observation
import WispCore

@MainActor @Observable
final class EngineConnectModel {
    private(set) var flow = EngineConnectFlow()
    private(set) var error: String?

    let login: EngineLogin

    @ObservationIgnored private let layout = RuntimeLayout(
        bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
    @ObservationIgnored private let environment: [String: String]

    private static let terminalID = "com.apple.Terminal"

    init(_ login: EngineLogin) {
        self.login = login
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("UV_") && $0.key != "PYTHONPATH" }
        environment["WISP_RESOURCES"] = layout.src.path
        self.environment = environment
    }

    var state: EngineConnectState { flow.state }

    static var scratchDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wisp-connect", isDirectory: true)
    }

    static func removeOldCommandFiles() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: scratchDirectory.path) else { return }
        for name in names where EngineLogin.isCommandFile(name) {
            try? fm.removeItem(at: scratchDirectory.appendingPathComponent(name))
        }
    }

    func check() async {
        let login = login
        let wisp = layout.wisp
        let environment = environment
        let found = await Task.detached { () -> (Bool, Bool) in
            let installed = Self.isInstalled(login)
            guard installed else { return (false, false) }
            return (true, Self.isLoggedIn(login, wisp: wisp, environment: environment))
        }.value
        flow.check(installed: found.0, loggedIn: found.1)
        if flow.state == .connected { EngineModel.shared.refresh() }
    }

    func open() {
        guard flow.state == .notConnected || flow.state == .timedOut else { return }
        error = nil
        do {
            let file = try Self.writeCommandFile(login)
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.terminalID) else {
                error = "Não encontrei o Terminal neste Mac."
                return
            }
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, failure in
                guard failure != nil else { return }
                Task { @MainActor in self?.error = "Não consegui abrir o Terminal." }
            }
            flow.opened()
        } catch {
            self.error = "Não consegui preparar o Terminal."
        }
    }

    func watch() async {
        guard flow.state == .waiting else { return }
        let login = login
        let wisp = layout.wisp
        let environment = environment
        while flow.state == .waiting {
            try? await Task.sleep(for: .seconds(EngineConnectFlow.pollInterval))
            if Task.isCancelled {
                flow.stopped()
                return
            }
            let loggedIn = await Task.detached { Self.isLoggedIn(login, wisp: wisp, environment: environment) }.value
            if Task.isCancelled {
                flow.stopped()
                return
            }
            flow.polled(loggedIn: loggedIn)
        }
        if flow.state == .connected { EngineModel.shared.refresh() }
    }

    func copyInstallCommand() {
        guard let command = login.installCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func openInstallPage() {
        NSWorkspace.shared.open(login.installURL)
    }

    private nonisolated static func isInstalled(_ login: EngineLogin) -> Bool {
        switch login {
        case .claude: (try? ClaudeLocator.resolve(configured: nil)) != nil
        case .codex: (try? CodexLocator.resolve(configured: nil)) != nil
        }
    }

    private nonisolated static func isLoggedIn(_ login: EngineLogin, wisp: URL, environment: [String: String]) -> Bool {
        let result = CommandRunner.run(
            executable: wisp, arguments: ["doctor", "--json", "--only", login.doctorCheck], environment: environment, timeout: 40)
        guard case .success(let output) = result, !output.timedOut,
              let report = try? JSONDecoder().decode(DoctorReport.self, from: output.stdout) else { return false }
        return report.checks.first { $0.id == login.doctorCheck }?.ok == true
    }

    private static func writeCommandFile(_ login: EngineLogin) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: scratchDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = scratchDirectory.appendingPathComponent(login.commandFileName(token: UUID().uuidString))
        try Data(login.script.utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}
