import Foundation

public struct LocalModel: Codable, Equatable, Identifiable, Sendable {
    public var tag: String
    public var name: String
    public var params: String
    public var sizeBytes: UInt64
    public var memoryBytes: UInt64
    public var tier: String
    public var contextTokens: Int
    public var speed: String
    public var limitations: String
    public var toolsReliable: Bool

    public var id: String { tag }

    public init(
        tag: String, name: String, params: String, sizeBytes: UInt64, memoryBytes: UInt64, tier: String,
        contextTokens: Int, speed: String, limitations: String, toolsReliable: Bool = true
    ) {
        self.toolsReliable = toolsReliable
        self.tag = tag
        self.name = name
        self.params = params
        self.sizeBytes = sizeBytes
        self.memoryBytes = memoryBytes
        self.tier = tier
        self.contextTokens = contextTokens
        self.speed = speed
        self.limitations = limitations
    }

    enum CodingKeys: String, CodingKey {
        case tag, name, params, tier, speed, limitations
        case sizeBytes = "size_bytes"
        case memoryBytes = "memory_bytes"
        case contextTokens = "context_tokens"
        case toolsReliable = "tools_reliable"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tag = try values.decode(String.self, forKey: .tag)
        name = try values.decode(String.self, forKey: .name)
        params = try values.decode(String.self, forKey: .params)
        sizeBytes = try values.decode(UInt64.self, forKey: .sizeBytes)
        memoryBytes = try values.decode(UInt64.self, forKey: .memoryBytes)
        tier = try values.decode(String.self, forKey: .tier)
        contextTokens = try values.decode(Int.self, forKey: .contextTokens)
        speed = try values.decode(String.self, forKey: .speed)
        limitations = try values.decode(String.self, forKey: .limitations)
        toolsReliable = try values.decodeIfPresent(Bool.self, forKey: .toolsReliable) ?? true
    }

    public var tierLabel: String {
        switch tier {
        case "pequeno": "Pequeno"
        case "medio": "Médio"
        case "grande": "Grande"
        default: tier
        }
    }

    public var speedLabel: String {
        switch speed {
        case "rapido": "rápido"
        case "medio": "velocidade média"
        case "lento": "lento"
        default: speed
        }
    }
}

public struct BackendStatus: Codable, Equatable, Sendable {
    public var kind: String
    public var available: Bool
    public var running: Bool
    public var url: String

    public init(kind: String, available: Bool, running: Bool, url: String = "") {
        self.kind = kind
        self.available = available
        self.running = running
        self.url = url
    }

    public var isMlx: Bool { kind == "mlx" }
}

public enum LocalModelPresence: Equatable, Sendable {
    case absent, resumable, downloading, downloaded, inUse
}

public struct LocalModelStatus: Codable, Equatable, Sendable {
    public var models: [LocalModel]
    public var diskMarginBytes: UInt64
    public var backend: BackendStatus
    public var installed: [String]
    public var downloading: [String]
    public var resumable: [String]
    public var active: String
    public var pensar: Bool

    public init(
        models: [LocalModel], diskMarginBytes: UInt64, backend: BackendStatus, installed: [String], active: String, pensar: Bool = false,
        downloading: [String] = [], resumable: [String] = []
    ) {
        self.downloading = downloading
        self.resumable = resumable
        self.pensar = pensar
        self.models = models
        self.diskMarginBytes = diskMarginBytes
        self.backend = backend
        self.installed = installed
        self.active = active
    }

    enum CodingKeys: String, CodingKey {
        case models, backend, installed, downloading, resumable, active, pensar
        case diskMarginBytes = "disk_margin_bytes"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        models = try values.decode([LocalModel].self, forKey: .models)
        diskMarginBytes = try values.decode(UInt64.self, forKey: .diskMarginBytes)
        backend = try values.decode(BackendStatus.self, forKey: .backend)
        installed = try values.decode([String].self, forKey: .installed)
        active = try values.decode(String.self, forKey: .active)
        downloading = try values.decodeIfPresent([String].self, forKey: .downloading) ?? []
        resumable = try values.decodeIfPresent([String].self, forKey: .resumable) ?? []
        pensar = try values.decodeIfPresent(Bool.self, forKey: .pensar) ?? false
    }

    public func presence(of tag: String) -> LocalModelPresence {
        if downloading.contains(tag) { return .downloading }
        if installed.contains(tag) { return active == tag ? .inUse : .downloaded }
        return resumable.contains(tag) ? .resumable : .absent
    }

    public static func decode(_ data: Data) -> LocalModelStatus? {
        guard let line = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline).first else { return nil }
        return try? JSONDecoder().decode(LocalModelStatus.self, from: Data(line.utf8))
    }
}

public enum ModelJobEvent: Equatable, Sendable {
    case progress(status: String, completed: UInt64, total: UInt64)
    case done
    case failed(String)

    public static func decode(line: String) -> ModelJobEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "progress":
            let number = { (key: String) -> UInt64 in (object[key] as? NSNumber)?.uint64Value ?? 0 }
            return .progress(status: object["status"] as? String ?? "", completed: number("completed"), total: number("total"))
        case "done": return .done
        case "error": return .failed(object["message"] as? String ?? "falhou")
        default: return nil
        }
    }
}
