import Foundation

public enum WispFolder {
    public static let defaultDirectory = "~/Wisp"

    public struct Layout: Equatable, Sendable {
        public let root: URL
        public let conversas: URL
        public let reunioes: URL
        public let brain: URL
        public let modelosPasta: URL
        public let anexos: URL
        public let skills: URL
        public let ferramentas: URL
        public let logs: URL
        public let agente: URL
        public let guardrails: URL
        public let modelos: URL
    }

    public struct Entry: Equatable, Sendable {
        public let name: String
        public let detail: String
    }

    public static let contents: [Entry] = [
        Entry(name: "conversas/", detail: "o histórico de cada conversa"),
        Entry(name: "reunioes/", detail: "gravações, transcrições e notas das reuniões"),
        Entry(name: "brain/", detail: "suas notas e o que o Wisp aprendeu (pode ficar em outra pasta)"),
        Entry(name: "modelos/", detail: "os modelos locais baixados pelo Wisp"),
        Entry(name: "anexos/", detail: "arquivos enviados pelo app e pelo Telegram"),
        Entry(name: "skills/", detail: "habilidades do agente"),
        Entry(name: "ferramentas/", detail: "ferramentas extras do agente"),
        Entry(name: "logs/", detail: "registros do bot e das mudanças de pasta"),
        Entry(name: "agente.md", detail: "as instruções do agente"),
        Entry(name: "guardrails.toml", detail: "o que o agente pode fazer"),
        Entry(name: "modelos.toml", detail: "o motor e os modelos"),
    ]

    public static func configURL(environment: [String: String], home: URL) -> URL {
        if let explicit = environment["WISP_CONFIG"], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("wisp/wisp.json")
    }

    public static func expand(_ path: String, home: URL) -> URL {
        let expanded = path == "~" || path.hasPrefix("~/") ? home.path + path.dropFirst() : path
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    public static func layout(raw: [String: Any]?, home: URL) -> Layout {
        let wispDir = (raw?["wisp_dir"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultDirectory
        let root = expand(wispDir, home: home)
        let brain = (raw?["brain"] as? String).flatMap { $0.isEmpty ? nil : $0 }.map { expand($0, home: home) }
        func folder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
        func file(_ name: String) -> URL { root.appendingPathComponent(name) }
        return Layout(
            root: root, conversas: folder("conversas"), reunioes: folder("reunioes"), brain: brain ?? folder("brain"), modelosPasta: folder("modelos"),
            anexos: folder("anexos"), skills: folder("skills"), ferramentas: folder("ferramentas"), logs: folder("logs"),
            agente: file("agente.md"), guardrails: file("guardrails.toml"), modelos: file("modelos.toml"))
    }

    public static func layout(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Layout {
        let data = try? Data(contentsOf: configURL(environment: environment, home: home))
        let raw = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return layout(raw: raw, home: home)
    }

    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        layout(environment: environment, home: home).root
    }

    public static func conversations(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        layout(environment: environment, home: home).conversas
    }

    public static func legacyMeetings(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        expand(defaultDirectory, home: home).appendingPathComponent("reunioes", isDirectory: true)
    }

    public static func isSameFolder(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        if let left = try? a.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject,
           let right = try? b.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject {
            return left.isEqual(right)
        }
        return a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    public static func isInside(_ child: URL, _ parent: URL) -> Bool {
        var current = child.resolvingSymlinksInPath()
        while true {
            if isSameFolder(current, parent) { return true }
            let up = current.deletingLastPathComponent()
            if up.path == current.path { return false }
            current = up
        }
    }

    public static func pendingMeetings(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Int {
        let old = legacyMeetings(home: home)
        let new = layout(environment: environment, home: home).reunioes
        guard !isInside(old, new), !isInside(new, old) else { return 0 }
        if (try? old.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return 0 }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: old.path)) ?? []
        return names.filter { $0 != "MOVIDO.txt" && !$0.hasPrefix(".wisp-part-") }.count
    }
}
