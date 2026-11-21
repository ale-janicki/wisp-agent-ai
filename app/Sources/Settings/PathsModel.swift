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

    @ObservationIgnored private let layout = RuntimeLayout(
        bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
    /// Read and child process share this one environment, so the file read here is the file `wisp config set` writes.
    @ObservationIgnored private let environment: [String: String]

    init() {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("UV_") && $0.key != "PYTHONPATH" }
        environment["WISP_RESOURCES"] = layout.src.path
        self.environment = environment
    }

    /// Same order as the CLI: `$WISP_CONFIG`, then `$XDG_CONFIG_HOME/wisp/wisp.json`, then `~/.config/wisp/wisp.json`.
    private var configURL: URL {
        if let explicit = environment["WISP_CONFIG"], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("wisp/wisp.json")
    }

    func refresh() {
        guard let data = try? Data(contentsOf: configURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        hasWispDir = raw["wisp_dir"] is String
        wispDir = (raw["wisp_dir"] as? String) ?? "~/Wisp"
        brain = raw["brain"] as? String
    }

    /// The configured path, or the default the CLI falls back to: `~/Wisp`, and `~/Wisp/brain` for the brain whatever
    /// the Wisp folder is (`setup/brain.py: DEFAULT_REL` is relative to home, not to `wisp_dir`).
    func path(_ key: Key) -> (text: String, isDefault: Bool) {
        switch key {
        case .wispDir: (wispDir, wispDir == "~/Wisp" && !hasWispDir)
        case .brain:
            if let brain { (brain, false) } else { ("~/Wisp/brain", true) }
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
