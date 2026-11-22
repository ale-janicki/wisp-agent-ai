import AppKit
import Observation
import os
import WispCore

@MainActor @Observable
final class BrainSettingsModel {
    static let shared = BrainSettingsModel()

    private(set) var folder: String?
    private(set) var learns = true
    private(set) var lessons: [LearnedLessons.Lesson] = []
    private(set) var pendingLessons: [LearnedLessons.Lesson] = []
    private(set) var profileIsLink = false
    private(set) var error: String?

    @ObservationIgnored private let file: WispConfigFile
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "brain-settings")

    init(file: WispConfigFile = WispConfigFile()) {
        self.file = file
        refresh()
    }

    func refresh() {
        folder = file.string("brain")
        learns = file.bool("brain_learn", default: true)
        let file = folder.flatMap { $0.isEmpty ? nil : learnedLessons(in: $0) }
        lessons = file?.lessons() ?? []
        pendingLessons = file?.pending() ?? []
        profileIsLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: ConversationViewModel.profileURL.path)) != nil
    }

    private(set) var creating = false

    var brainMissing: Bool {
        guard let folder, !folder.isEmpty else { return true }
        var isDirectory: ObjCBool = false
        return !(FileManager.default.fileExists(atPath: (folder as NSString).expandingTildeInPath, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    func createBrain() {
        guard !creating else { return }
        creating = true
        error = nil
        Task {
            let problem = await runBrainSetup()
            creating = false
            error = problem
            refresh()
            (NSApp.delegate as? AppDelegate)?.reloadProfile()
        }
    }

    private func runBrainSetup() async -> String? {
        for arguments in [["setup", "brain", "--json"], ["setup", "profile", "--json"]] {
            guard case .success(let output) = await runWisp(arguments, timeout: 120), !output.timedOut,
                  let report = try? JSONDecoder().decode(SetupReport.self, from: output.stdout) else {
                return "Não consegui rodar o comando do Wisp."
            }
            if report.status == .failed || report.status == .needsUser {
                return report.data["step"] == "system" ? SetupPlan.brainDeferredNote : report.summary.prefix(1).uppercased() + report.summary.dropFirst()
            }
        }
        return nil
    }

    var displayFolder: String {
        guard let folder, !folder.isEmpty else { return "Nenhuma pasta escolhida" }
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Escolher"
        panel.message = "Escolha a pasta do seu brain."
        if let folder { panel.directoryURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath) }
        guard AppSettings.shared.persists, panel.runModal() == .OK, let url = panel.url else { return }
        write {
            try file.setString("brain", to: url.path)
            try ProfileMemoryFile(url: ConversationViewModel.profileURL).setRoot(url.path)
        }
    }

    func setLearns(_ on: Bool) {
        guard AppSettings.shared.persists else { return }
        write { try file.setBool("brain_learn", to: on) }
    }

    func forget(_ lesson: LearnedLessons.Lesson) {
        change(lesson) { try $0.remove($1) }
    }

    func confirm(_ lesson: LearnedLessons.Lesson) {
        change(lesson) { try $0.confirm($1) }
    }

    func discard(_ lesson: LearnedLessons.Lesson) {
        change(lesson) { try $0.discard($1) }
    }

    private func change(_ lesson: LearnedLessons.Lesson, _ action: (LearnedLessons, LearnedLessons.Lesson) throws -> Bool) {
        guard AppSettings.shared.persists, let folder, !folder.isEmpty else { return }
        write { _ = try action(learnedLessons(in: folder), lesson) }
    }

    private func learnedLessons(in folder: String) -> LearnedLessons {
        LearnedLessons(brain: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath))
    }

    private func write(_ change: () throws -> Void) {
        error = nil
        do {
            try change()
        } catch {
            log.error("wisp.json write failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Não consegui salvar no wisp.json: \(error.localizedDescription)"
        }
        refresh()
    }
}
