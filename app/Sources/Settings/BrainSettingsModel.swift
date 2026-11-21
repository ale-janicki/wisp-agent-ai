import AppKit
import Observation
import os
import WispCore

@MainActor @Observable
final class BrainSettingsModel {
    static let shared = BrainSettingsModel()

    private(set) var folder: String?
    private(set) var learns = true
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
        profileIsLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: ConversationViewModel.profileURL.path)) != nil
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
