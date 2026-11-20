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

    public var id: String { tag }

    public init(
        tag: String, name: String, params: String, sizeBytes: UInt64, memoryBytes: UInt64, tier: String,
        contextTokens: Int, speed: String, limitations: String
    ) {
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

public struct OllamaStatus: Codable, Equatable, Sendable {
    public var installed: Bool
    public var running: Bool

    public init(installed: Bool, running: Bool) {
        self.installed = installed
        self.running = running
    }
}

public struct LocalModelStatus: Codable, Equatable, Sendable {
    public var models: [LocalModel]
    public var diskMarginBytes: UInt64
    public var ollama: OllamaStatus
    public var installed: [String]
    public var active: String

    public init(models: [LocalModel], diskMarginBytes: UInt64, ollama: OllamaStatus, installed: [String], active: String) {
        self.models = models
        self.diskMarginBytes = diskMarginBytes
        self.ollama = ollama
        self.installed = installed
        self.active = active
    }

    enum CodingKeys: String, CodingKey {
        case models, ollama, installed, active
        case diskMarginBytes = "disk_margin_bytes"
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
