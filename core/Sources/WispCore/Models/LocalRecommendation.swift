import Foundation

public struct LocalPick: Equatable, Sendable {
    public var tag: String
    public var name: String
    public var sizeBytes: UInt64
    public var tokensPerSecond: UInt64?
    public var wordsPerSecond: UInt64?
    public var reason: String
}

public struct LocalRecommendation: Equatable, Sendable {
    public var chipFamily: String?
    public var bandwidthGBs: UInt64?
    public var best: LocalPick?
    public var fastest: LocalPick?
    public var notes: [String]

    public var isSameModel: Bool { best != nil && best?.tag == fastest?.tag }
}

public enum LocalAdvisor {
    public static let bandwidthGBs: [String: UInt64] = [
        "M1": 67, "M1 Pro": 200, "M1 Max": 400, "M1 Ultra": 800,
        "M2": 100, "M2 Pro": 200, "M2 Max": 400, "M2 Ultra": 800,
        "M3": 100, "M3 Pro": 150, "M3 Max": 300, "M3 Ultra": 800,
        "M4": 120, "M4 Pro": 273, "M4 Max": 410,
        "M5": 153,
    ]
    public static let needsAppleSilicon =
        "o MLX local precisa de um Mac com Apple silicon e este não tem; aponte para um servidor compatível com OpenAI "
        + "(wisp local backend openai --url ENDEREÇO --model MODELO) ou use o Claude ou o Codex, que rodam na assinatura"

    public static func appleSilicon(_ chip: String) -> Bool {
        chip.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("apple")
    }

    static let subscription = "use o Claude ou o Codex, que rodam na assinatura"
    static let gibibyte: UInt64 = 1 << 30
    static let lowMemoryHeadroom: UInt64 = 2 << 30
    public static let lowMemoryReason = "o Mac está com pouca memória livre agora"

    public static func chipFamily(_ chip: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\bApple\s+M(\d+)(?:\s+(Pro|Max|Ultra))?\b"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: chip, range: NSRange(chip.startIndex..., in: chip)),
              let number = Range(match.range(at: 1), in: chip) else { return nil }
        let family = "M\(chip[number])"
        guard let tier = Range(match.range(at: 2), in: chip) else { return family }
        return "\(family) \(chip[tier].prefix(1).uppercased() + chip[tier].dropFirst().lowercased())"
    }

    public static func bandwidth(chip: String) -> UInt64? {
        chipFamily(chip).flatMap { bandwidthGBs[$0] }
    }

    public static func tokensPerSecond(bandwidth: UInt64, sizeBytes: UInt64) -> UInt64 {
        (bandwidth * 1_000_000_000 + sizeBytes / 2) / sizeBytes
    }

    public static func wordsPerSecond(bandwidth: UInt64, sizeBytes: UInt64) -> UInt64 {
        (bandwidth * 1_000_000_000 * 3 + (sizeBytes * 4) / 2) / (sizeBytes * 4)
    }

    public static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1e9).replacingOccurrences(of: ".", with: ",")
    }

    static func memoryLabel(_ bytes: UInt64) -> String {
        "\((bytes + gibibyte / 2) / gibibyte) GB"
    }

    static func speedText(_ words: UInt64?) -> String {
        words.map { "~\($0) palavras/s (estimativa)" } ?? "sem estimativa de velocidade neste chip"
    }

    static func fitsComfortably(_ model: LocalModel, memory: UInt64) -> Bool {
        memory > 0 && model.memoryBytes * 2 <= memory
    }

    private static func pick(_ model: LocalModel, bandwidth: UInt64?, reason: String) -> LocalPick {
        LocalPick(
            tag: model.tag, name: model.name, sizeBytes: model.sizeBytes,
            tokensPerSecond: bandwidth.map { tokensPerSecond(bandwidth: $0, sizeBytes: model.sizeBytes) },
            wordsPerSecond: bandwidth.map { wordsPerSecond(bandwidth: $0, sizeBytes: model.sizeBytes) }, reason: reason)
    }

    public static func recommend(hardware: HardwareProfile, models: [LocalModel], diskMargin: UInt64) -> LocalRecommendation {
        guard appleSilicon(hardware.chip) else {
            return LocalRecommendation(chipFamily: nil, bandwidthGBs: nil, best: nil, fastest: nil, notes: [needsAppleSilicon])
        }
        let bandwidth = bandwidth(chip: hardware.chip)
        let memory = models.filter { fitsComfortably($0, memory: hardware.totalMemory) }
        let usable = memory.filter { hardware.freeDisk >= $0.sizeBytes + diskMargin }
        var notes: [String] = []
        var best: LocalPick?
        var fastest: LocalPick?
        if var top = usable.max(by: { $0.sizeBytes < $1.sizeBytes }) {
            var pressure = ""
            let lighter = usable.filter { $0.sizeBytes < top.sizeBytes }
            if hardware.availableMemory > 0, hardware.availableMemory < top.memoryBytes + lowMemoryHeadroom,
               let next = lighter.max(by: { $0.sizeBytes < $1.sizeBytes }) {
                top = next
                pressure = "; \(lowMemoryReason)"
            }
            let words = bandwidth.map { wordsPerSecond(bandwidth: $0, sizeBytes: top.sizeBytes) }
            let weak = top.toolsReliable ? "" : "; erra mais ao usar ferramentas"
            best = pick(top, bandwidth: bandwidth, reason: "cabe com folga em \(memoryLabel(hardware.totalMemory)); \(speedText(words))\(weak)\(pressure)")
            if let small = usable.filter(\.toolsReliable).min(by: { $0.sizeBytes < $1.sizeBytes }) {
                let smallWords = bandwidth.map { wordsPerSecond(bandwidth: $0, sizeBytes: small.sizeBytes) }
                fastest = pick(small, bandwidth: bandwidth, reason: "o menor que ainda usa ferramentas direito; \(speedText(smallWords))")
            } else {
                notes.append("nenhum modelo que use ferramentas direito cabe com folga na memória e no disco deste Mac")
            }
        } else if let smallest = memory.min(by: { $0.sizeBytes < $1.sizeBytes }) {
            let short = smallest.sizeBytes + diskMargin - hardware.freeDisk
            notes.append(
                "falta espaço em disco: o menor modelo que cabe precisa de \(gigabytes(smallest.sizeBytes)) GB mais "
                    + "\(gigabytes(diskMargin)) GB de folga e faltam \(gigabytes(short)) GB; libere espaço ou \(subscription)")
        } else {
            notes.append("nenhum modelo local cabe com folga na memória deste Mac (\(memoryLabel(hardware.totalMemory))); \(subscription)")
        }
        return LocalRecommendation(
            chipFamily: chipFamily(hardware.chip), bandwidthGBs: bandwidth, best: best, fastest: fastest, notes: notes)
    }
}
