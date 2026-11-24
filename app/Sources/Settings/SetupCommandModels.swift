import AppKit
import Foundation
import Observation
import WispCore

@MainActor
func runWisp(_ arguments: [String], stdin: Data? = nil, timeout: TimeInterval) async -> Result<CommandOutput, BlockCommandError> {
    let layout = RuntimeLayout(bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
    var environment = RuntimeEnvironment.forRuntime()
    environment["WISP_RESOURCES"] = layout.src.path
    let executable = layout.wisp
    let final = environment
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: CommandRunner.run(
                executable: executable, arguments: arguments, stdin: stdin, environment: final, timeout: timeout))
        }
    }
}

@MainActor @Observable
final class TelegramConnectModel {
    static let shared = TelegramConnectModel()

    var token = ""
    private(set) var configured = false
    private(set) var tokenStored = false
    private(set) var busy = false
    private(set) var message: String?
    private(set) var failed = false

    func refresh() {
        Task {
            guard case .success(let output) = await runWisp(["doctor", "--json", "--only", "telegram"], timeout: 20),
                  let report = try? JSONDecoder().decode(DoctorReport.self, from: output.stdout) else { return }
            configured = SetupFlow.telegramConfigured(doctor: report)
        }
    }

    func connect() {
        let text = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        run(["--token-stdin"], stdin: Data(text.utf8)) { [self] report in
            tokenStored = report.status == .needsUser
            if report.status != .failed { token = "" }
        }
    }

    func discover() { run(["--discover"], timeout: 150) { _ in } }

    func disconnect() {
        run(["--skip"]) { [self] _ in
            tokenStored = false
        }
    }

    private func run(_ arguments: [String], stdin: Data? = nil, timeout: TimeInterval = 60, done: @escaping (SetupReport) -> Void) {
        guard !busy else { return }
        busy = true
        message = nil
        failed = false
        Task {
            let result = await runWisp(["setup", "telegram"] + arguments + ["--json"], stdin: stdin, timeout: timeout)
            busy = false
            guard case .success(let output) = result, !output.timedOut,
                  let report = try? JSONDecoder().decode(SetupReport.self, from: output.stdout) else {
                failed = true
                message = "Não consegui falar com o Telegram. Tente de novo."
                return
            }
            failed = report.status == .failed
            message = report.summary.prefix(1).uppercased() + report.summary.dropFirst()
            done(report)
            refresh()
            (NSApp.delegate as? AppDelegate)?.reloadProfile()
        }
    }
}

@MainActor @Observable
final class ProfileEditModel {
    static let shared = ProfileEditModel()

    var name = "Wisp"
    var userName = NSFullUserName()
    var avatar: URL?
    private(set) var busy = false
    private(set) var message: String?
    private(set) var failed = false

    func load() {
        guard let profile = try? ProfileLoader.load(from: ConversationViewModel.profileURL) else { return }
        name = profile.persona.name
        if let user = profile.persona.user, !user.isEmpty { userName = user }
        avatar = profile.persona.avatar.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    var canSave: Bool {
        !busy && !name.trimmingCharacters(in: .whitespaces).isEmpty && !userName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func save() {
        guard canSave else { return }
        busy = true
        message = nil
        var arguments = ["setup", "profile", "--name", name, "--user-name", userName]
        if let avatar { arguments += ["--avatar", avatar.path] }
        Task {
            let result = await runWisp(arguments + ["--json"], timeout: 60)
            busy = false
            guard case .success(let output) = result, !output.timedOut,
                  let report = try? JSONDecoder().decode(SetupReport.self, from: output.stdout) else {
                failed = true
                message = "Não consegui salvar o perfil."
                return
            }
            failed = report.status == .failed
            message = report.summary.prefix(1).uppercased() + report.summary.dropFirst()
            (NSApp.delegate as? AppDelegate)?.reloadProfile()
        }
    }
}
