import AppKit
import Foundation
import Observation
import WispCore

/// The two folders Ajustes > Geral shows: where the Wisp folder and the brain live. Reads `wisp.json`; changes go through
/// `wisp config set`, which saves, seeds what is missing and re-renders Claude Code. Nothing is ever moved.
@MainActor @Observable
final class PathsModel {
    enum Key: String { case wispDir = "wisp_dir", brain }

    static let shared = PathsModel()

    private(set) var wispDir = "~/Wisp"
    private(set) var brain: String?
    private(set) var hasWispDir = false
    private(set) var busy = false
    private(set) var errors: [Key: String] = [:]
    private(set) var pendingMeetings = 0
    private(set) var meetingsMove: MeetingsMove = .idle

    enum MeetingsMove: Equatable {
        case idle, moving(done: Int, total: Int), finished(String), failed(String)
    }

    @ObservationIgnored private let layout = RuntimeLayout(
        bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
    /// Read and child process share this one environment, so the file read here is the file `wisp config set` writes.
    @ObservationIgnored private let environment: [String: String]

    init() {
        var environment = RuntimeEnvironment.forRuntime()
        environment["WISP_RESOURCES"] = layout.src.path
        self.environment = environment
    }

    /// Same order as the CLI: `$WISP_CONFIG`, then `$XDG_CONFIG_HOME/wisp/wisp.json`, then `~/.config/wisp/wisp.json`.
    private var configURL: URL {
        WispFolder.configURL(environment: environment, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    @ObservationIgnored private var meetingsStream: LineStream?

    func refresh() {
        pendingMeetings = WispFolder.pendingMeetings(
            environment: environment, home: FileManager.default.homeDirectoryForCurrentUser)
        guard let data = try? Data(contentsOf: configURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        hasWispDir = raw["wisp_dir"] is String
        wispDir = (raw["wisp_dir"] as? String) ?? "~/Wisp"
        brain = raw["brain"] as? String
    }

    func path(_ key: Key) -> (text: String, isDefault: Bool) {
        switch key {
        case .wispDir: (wispDir, wispDir == "~/Wisp" && !hasWispDir)
        case .brain:
            if let brain { (brain, false) } else { ("\(wispDir)/brain", true) }
        }
    }

    func url(_ key: Key) -> URL {
        URL(fileURLWithPath: (path(key).text as NSString).expandingTildeInPath, isDirectory: true)
    }

    func reveal(_ key: Key) {
        let url = url(key)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            errors[key] = "Essa pasta ainda não existe."
        }
    }

    func choose(_ key: Key) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Escolher"
        panel.directoryURL = url(key)
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        change(key, to: picked.path)
    }

    func recordingRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [WispFolder.legacyMeetings(home: home), WispFolder.layout(environment: environment, home: home).reunioes]
    }

    nonisolated static func recordingActive(in roots: [URL]) -> Bool {
        roots.contains { RecordingFolder.hasActiveRecording(in: $0) }
    }

    func moveMeetings() {
        guard meetingsStream == nil else {
            if case .moving = meetingsMove { return }
            meetingsMove = .failed("Já está movendo.")
            return
        }
        guard !Self.recordingActive(in: recordingRoots()) else {
            meetingsMove = .failed("Há uma reunião sendo gravada.")
            return
        }
        let stream = LineStream()
        meetingsStream = stream
        meetingsMove = .moving(done: 0, total: pendingMeetings)
        let executable = layout.wisp
        let environment = environment
        Task {
            let outcome = Outcome()
            let result = await stream.run(
                executable: executable, arguments: ["folder", "migrate", "--reunioes", "--json"], environment: environment
            ) { line in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                if object["type"] as? String == "progress", let done = object["done"] as? Int, let total = object["total"] as? Int {
                    Task { @MainActor in self.meetingsMove = .moving(done: done, total: total) }
                } else if object["step"] != nil {
                    outcome.report = (object["status"] as? String ?? "", object["summary"] as? String ?? "")
                }
            }
            meetingsStream = nil
            switch result {
            case .failure:
                meetingsMove = .failed("Não consegui rodar o wisp.")
            case .success:
                if let report = outcome.report, report.status != "failed" {
                    meetingsMove = .finished(report.summary)
                } else {
                    meetingsMove = .failed(outcome.report?.summary ?? "O wisp não respondeu.")
                }
            }
            refresh()
        }
    }

    private final class Outcome: @unchecked Sendable {
        var report: (status: String, summary: String)?
    }

    private func change(_ key: Key, to path: String) {
        guard !busy else { return }
        busy = true
        errors[key] = nil
        let executable = layout.wisp
        let environment = environment
        let arguments = ["config", "set", key.rawValue, path, "--json"]
        Task {
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: CommandRunner.run(
                        executable: executable, arguments: arguments, environment: environment, timeout: 120))
                }
            }
            busy = false
            switch result {
            case .failure:
                errors[key] = "Não consegui rodar o wisp."
            case .success(let output):
                let report = try? JSONDecoder().decode(SetupReport.self, from: output.stdout)
                if let report, report.status != .failed {
                    errors[key] = nil
                } else {
                    errors[key] = report?.summary ?? (output.timedOut ? "O wisp demorou demais." : "O wisp não respondeu.")
                }
            }
            refresh()
        }
    }
}
