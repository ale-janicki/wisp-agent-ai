import Foundation
import Observation
import WispCore

/// What the AI can reach today: the MCP servers of the active engine and the command-line tools on the login PATH.
/// Scanned when the Integrações pane appears or on "Atualizar", never at app start.
@MainActor @Observable
final class ToolsInventoryModel {
    static let shared = ToolsInventoryModel()

    private(set) var engine: EngineKind = .claude
    private(set) var servers: [McpServerInfo] = []
    private(set) var tools: [CliStatus] = []
    private(set) var scanning = false
    private(set) var scanned = false

    @ObservationIgnored private let scanner = CliScanner()
    @ObservationIgnored private var rescanQueued = false

    private init() {}

    var installed: [CliStatus] { tools.filter(\.isInstalled) }
    var missing: [CliStatus] { tools.filter { !$0.isInstalled } }

    /// A forced refresh while a scan runs is queued and runs once the current scan ends, so the click is not lost.
    func refresh(force: Bool = false) {
        if scanning {
            if force { rescanQueued = true }
            return
        }
        if force { scanner.clearCache() }
        scanning = true
        engine = EngineModel.shared.active
        let engine = engine
        let scanner = scanner
        let cwd = Self.agentCwd()
        DispatchQueue.global(qos: .background).async {
            let servers = McpServers.scan(engine: engine, cwd: cwd)
            let tools = scanner.scan(path: ClaudeLocator.effectivePATH)
            Task { @MainActor in
                let model = ToolsInventoryModel.shared
                model.servers = servers
                model.tools = tools
                model.scanning = false
                model.scanned = true
                if model.rescanQueued {
                    model.rescanQueued = false
                    model.refresh(force: true)
                }
            }
        }
    }

    nonisolated private static func agentCwd() -> String {
        let profile = (try? ProfileLoader.load(from: ConversationViewModel.profileURL)) ?? .default
        return expandTilde(profile.agent.cwd)
    }
}
