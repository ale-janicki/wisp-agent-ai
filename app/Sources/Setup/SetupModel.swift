import AppKit
import Foundation
import Observation
import os
import WispCore

@MainActor @Observable
final class SetupModel {
    enum RowState: Equatable {
        case pending, running, done, skipped
        case needsUser(String)
        case failed(String)
    }

    struct StepRow: Identifiable {
        let id: SetupStepID
        var state: RowState = .pending
        var report: SetupReport?
        /// The command line last run (never carries the token: that goes over stdin) and the tail of its stderr.
        var command = ""
        var liveLog = ""
    }

    private(set) var rows = SetupStepID.allCases.map { StepRow(id: $0) }
    var current: SetupStepID = .system {
        didSet {
            if current == .login, oldValue != .login { loginTerminal.start(model: self) }
            if oldValue == .login, current != .login { loginTerminal.stop() }
        }
    }
    var detailsOpen = false

    var withHomebrew = false
    var brainFolder: URL?
    var profileName = "Wisp"
    var profileUserName = NSFullUserName()
    var profileAvatar: URL?
    var telegramToken = ""

    /// The doctor could not be read: the wizard stays on System with a retry instead of guessing.
    private(set) var doctorFailed = false
    /// The Telegram token step succeeded in this session, so only the group search is left.
    private(set) var telegramTokenStored = false
    /// The wait for Apple's installer ran out: one sentence and a "verificar" button.
    private(set) var pollTimedOut = false

    let wisp: URL
    let homeOverride: URL?
    /// A re-run, or a profile that already exists: closing the window must never re-arm the wizard gate.
    let existingInstall: Bool

    private let log = Logger(subsystem: "com.owner.wisp", category: "setup")
    private var pollTask: Task<Void, Never>?
    /// The Login step's terminal; it lives here so closing the window or quitting ends it with the model.
    @ObservationIgnored let loginTerminal = LoginTerminalSession()
    private var systemArguments: [String] = []

    /// Steps whose child gets `--dry-run` under a DEBUG home override: the ones that install software or reach the network.
    private static let dryRunSteps: Set<SetupStepID> = [.system, .telegram]
    private static let pollInterval: Duration = .seconds(3)
    private static let pollLimit: TimeInterval = 30 * 60

    init(wisp: URL, homeOverride: URL? = nil, existingInstall: Bool = false) {
        self.wisp = wisp
        self.homeOverride = homeOverride
        self.existingInstall = existingInstall
    }

    // MARK: Reading

    var home: URL { homeOverride ?? FileManager.default.homeDirectoryForCurrentUser }

    var defaultBrainFolder: URL { home.appendingPathComponent("Wisp/brain", isDirectory: true) }

    var stateURL: URL {
        if let homeOverride {
            return homeOverride.appendingPathComponent("Library/Application Support/Wisp/setup.json")
        }
        return Self.defaultStateURL
    }

    static var defaultStateURL: URL { ConversationStore.defaultDirectory.appendingPathComponent("setup.json") }

    func row(_ id: SetupStepID) -> StepRow { rows[rows.firstIndex { $0.id == id } ?? 0] }

    var isBusy: Bool { rows.contains { $0.state == .running } }

    var canAdvance: Bool {
        switch row(current).state {
        case .done, .skipped: current != .done
        default: false
        }
    }

    // MARK: Doctor

    func refreshFromDoctor() async {
        let state = (try? SetupState.load(from: stateURL)) ?? SetupState()
        guard let report = await doctor(only: nil) else {
            doctorFailed = true
            current = SetupFlow.openingStep(doctor: nil, state: state)
            update(.system) {
                $0.state = .failed("Não consegui conferir o seu Mac. Tente de novo.")
                $0.liveLog = "wisp doctor --json não respondeu"
            }
            return
        }
        doctorFailed = false
        let automatic: [SetupStepID] = [.system, .login, .brain, .harness, .profile]
        for step in SetupStepID.allCases where step != .done {
            let checks = report.checks.filter { $0.step == step.rawValue }
            if state.skipped.contains(step.rawValue) {
                update(step) { $0.state = .skipped }
            } else if automatic.contains(step), !checks.isEmpty, checks.allSatisfy(\.ok) {
                update(step) { $0.state = .done }
            } else if state.completed.contains(step.rawValue) {
                update(step) { $0.state = .done }
            }
        }
        current = SetupFlow.openingStep(doctor: report, state: state)
    }

    private func doctor(only: String?, timeout: TimeInterval = 40) async -> DoctorReport? {
        let arguments = ["doctor", "--json"] + (only.map { ["--only", $0] } ?? [])
        guard case .success(let output) = await execute(arguments, stdin: nil, timeout: timeout) else { return nil }
        return try? JSONDecoder().decode(DoctorReport.self, from: output.stdout)
    }

    /// The `claude_login` check alone; nil when the doctor did not answer in time or did not list it.
    func claudeLoggedIn() async -> Bool? {
        guard let report = await doctor(only: "claude_login", timeout: 20) else { return nil }
        return report.checks.first { $0.id == "claude_login" }?.ok
    }

    // MARK: Steps

    func run(_ step: SetupStepID, arguments: [String] = [], stdin: Data? = nil) async {
        guard !isBusy, step != .done, step != .login, step != .spotify else { return }
        pollTask?.cancel()
        pollTimedOut = false
        if step == .system {
            systemArguments = arguments
            doctorFailed = false
        }
        var command = ["setup", step.rawValue] + arguments + ["--json"]
        if homeOverride != nil, Self.dryRunSteps.contains(step), !arguments.contains("--skip") { command.append("--dry-run") }
        update(step) {
            $0.state = .running
            $0.command = "wisp " + command.joined(separator: " ")
            $0.liveLog = ""
        }
        let timeout: TimeInterval = step == .system ? 900 : 120
        let result = await execute(command, stdin: stdin, timeout: timeout)
        let skippedByUser = arguments.contains("--skip")
        switch result {
        case .failure(let error):
            update(step) {
                $0.state = .failed("Não consegui rodar o comando do Wisp.")
                $0.liveLog = error.localizedDescription
            }
        case .success(let output):
            guard !output.timedOut else {
                update(step) { $0.state = .failed("O passo demorou demais. Tente de novo."); $0.liveLog = Self.tail(output.stderr) }
                return
            }
            guard let report = try? JSONDecoder().decode(SetupReport.self, from: output.stdout) else {
                update(step) {
                    $0.state = .failed("O Wisp não entendeu a resposta deste passo.")
                    $0.liveLog = Self.tail(output.stderr)
                }
                return
            }
            update(step) {
                $0.report = report
                $0.liveLog = Self.tail(output.stderr)
                switch report.status {
                case .done: $0.state = .done
                case .skipped: $0.state = skippedByUser ? .skipped : .done
                case .needsUser: $0.state = .needsUser(report.summary)
                case .failed: $0.state = .failed(report.summary)
                }
            }
            if step == .telegram, arguments.contains("--token-stdin") {
                telegramTokenStored = report.status == .needsUser
            }
            record(step, report.status, skippedByUser: skippedByUser)
            if step == .system, report.status == .needsUser { startPollingSystem() }
        }
    }

    /// Marks a step the user chose to leave for later: Spotify, and Claude's login.
    func skip(_ step: SetupStepID) {
        update(step) { $0.state = .skipped }
        record(step, .skipped, skippedByUser: true)
    }

    /// A step with no command of its own (Spotify) that the user completed in the view.
    func markDone(_ step: SetupStepID) {
        update(step) { $0.state = .done }
        record(step, .done, skippedByUser: false)
    }

    func advance() {
        guard let index = SetupStepID.allCases.firstIndex(of: current), index + 1 < SetupStepID.allCases.count else { return }
        current = SetupStepID.allCases[index + 1]
    }

    func finish() {
        pollTask?.cancel()
        loginTerminal.stop()
        var state = (try? SetupState.load(from: stateURL)) ?? SetupState()
        state.finishedAt = Date()
        state.completed.insert(SetupStepID.done.rawValue)
        do { try state.save(to: stateURL) } catch { log.error("setup state not saved: \(error.localizedDescription, privacy: .public)") }
        update(.done) { $0.state = .done }
    }

    /// The window closed or the app is quitting: no poll and no `claude` child outlive it.
    func cancelPolling(blocking: Bool = false) {
        pollTask?.cancel()
        loginTerminal.stop(blocking: blocking)
    }

    // MARK: Waiting for Apple's installer

    /// Polls until the Command Line Tools are in (Claude Code is installed by the system step itself, so it is
    /// not waited for), then runs System again with the arguments of the run that asked for the wait.
    /// Stops when the step leaves needsUser, when the window closes, or after 30 minutes.
    private func startPollingSystem() {
        pollTask?.cancel()
        let deadline = Date().addingTimeInterval(Self.pollLimit)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                guard case .needsUser = self.row(.system).state else { return }
                if Date() > deadline {
                    self.pollTimedOut = true
                    self.update(.system) {
                        $0.state = .needsUser("Ainda esperando as ferramentas da Apple — termine a instalação e toque em verificar")
                    }
                    return
                }
                guard let report = await self.doctor(only: "clt,claude"), SetupFlow.shouldRerunSystem(doctor: report) else { continue }
                await self.rerunSystemAfterWait()
                return
            }
        }
    }

    private func rerunSystemAfterWait() async {
        pollTask = nil
        await run(.system, arguments: systemArguments)
    }

    /// The "verificar" button after the wait timed out, and the retry after an unreadable doctor.
    func verifySystem() async {
        if doctorFailed {
            await refreshFromDoctor()
            return
        }
        guard let report = await doctor(only: "clt,claude") else { return }
        if SetupFlow.shouldRerunSystem(doctor: report) {
            await rerunSystemAfterWait()
        } else {
            pollTimedOut = false
            update(.system) { $0.state = .needsUser("Clique em Instalar na janela da Apple; o Wisp continua sozinho quando terminar") }
            startPollingSystem()
        }
    }

    // MARK: Plumbing

    private func update(_ step: SetupStepID, _ change: (inout StepRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == step }) else { return }
        change(&rows[index])
    }

    private func record(_ step: SetupStepID, _ status: SetupReport.Status, skippedByUser: Bool) {
        var state = SetupFlow.persisted(try? SetupState.load(from: stateURL), existingInstall: existingInstall, now: Date())
        switch status {
        case .done:
            state.completed.insert(step.rawValue)
            state.skipped.remove(step.rawValue)
        case .skipped:
            if skippedByUser { state.skipped.insert(step.rawValue) } else { state.completed.insert(step.rawValue) }
        case .needsUser, .failed: return
        }
        do { try state.save(to: stateURL) } catch { log.error("setup state not saved: \(error.localizedDescription, privacy: .public)") }
    }

    /// Every child runs `wisp` by absolute path with the runtime's sources named, never through the login-shell PATH.
    private func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("UV_") && $0.key != "PYTHONPATH" }
        let runtimeRoot = wisp.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        environment["WISP_RESOURCES"] = runtimeRoot.appendingPathComponent("src").path
        if let homeOverride {
            environment = environment.filter { !$0.key.hasPrefix("XDG_") && $0.key != "WISP_CONFIG" }
            environment["HOME"] = homeOverride.path
        }
        return environment
    }

    private func execute(_ arguments: [String], stdin: Data?, timeout: TimeInterval) async -> Result<CommandOutput, BlockCommandError> {
        let executable = wisp
        let environment = childEnvironment()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: CommandRunner.run(
                    executable: executable, arguments: arguments, stdin: stdin, environment: environment, timeout: timeout))
            }
        }
    }

    private static func tail(_ data: Data) -> String {
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(6)
        return lines.joined(separator: "\n")
    }
}
