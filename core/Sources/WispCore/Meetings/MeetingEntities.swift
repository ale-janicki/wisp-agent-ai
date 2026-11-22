import Foundation

public enum EntityDetector {
    public static let maximum = 6

    static let keywords: Set<String> = [
        "cliente", "projeto", "empresa", "contrato", "proposta", "fornecedor", "produto", "sistema", "ferramenta", "squad",
        "client", "project", "company", "contract", "vendor", "product", "tool",
    ]
    static let fillers: Set<String> = ["o", "a", "os", "as", "um", "uma", "de", "do", "da", "dos", "das", "the", "of", "our", "nosso", "nossa", "esse", "essa", "este", "esta"]
    static let notEntities: Set<String> = [
        "você", "voce", "outros", "eu", "ele", "ela", "nós", "nos", "eles", "elas", "então", "entao", "mas", "bom", "boa", "sim", "não", "nao",
        "tá", "ta", "ok", "olá", "ola", "oi", "obrigado", "obrigada", "porque", "também", "tambem", "agora", "aqui", "isso", "isto", "pois",
        "the", "this", "that", "yes", "no", "hello", "thanks", "well", "so", "and", "but", "right",
        "segunda", "terça", "terca", "quarta", "quinta", "sexta", "sábado", "sabado", "domingo", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday", "sunday", "janeiro", "fevereiro", "março", "marco", "abril", "maio", "junho", "julho", "agosto",
        "setembro", "outubro", "novembro", "dezembro", "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    ]

    public static func candidates(in text: String) -> [String] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var found: [String] = []
        var index = 0
        while index < tokens.count {
            let word = trimmed(tokens[index])
            let lowered = word.lowercased()
            let startsSentence = index == 0 || endsSentence(tokens[index - 1])
            if keywords.contains(lowered) {
                let name = following(tokens, after: index)
                if !name.isEmpty { found.append(name.joined(separator: " ")) }
                index += 1 + name.count
                continue
            }
            if isCapitalised(word), !notEntities.contains(lowered) {
                var run = [word]
                var next = index + 1
                while next < tokens.count, !endsSentence(tokens[next - 1]) {
                    let candidate = trimmed(tokens[next])
                    guard isCapitalised(candidate), !notEntities.contains(candidate.lowercased()) else { break }
                    run.append(candidate)
                    next += 1
                }
                if !startsSentence || run.count > 1 { found.append(run.joined(separator: " ")) }
                index = next
                continue
            }
            if isCode(word) { found.append(word) }
            index += 1
        }
        return unique(found).prefix(maximum).map { $0 }
    }

    public static func candidates(in segments: [MeetingSegment], includeOthers: Bool) -> [String] {
        let spoken = segments.filter { $0.isFinal && (includeOthers || $0.channel == .mic) }
        return candidates(in: spoken.map(\.text).joined(separator: ". "))
    }

    public static func key(_ query: String) -> String {
        query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func following(_ tokens: [String], after index: Int) -> [String] {
        var name: [String] = []
        var next = index + 1
        while next < tokens.count, name.count < 2 {
            let word = trimmed(tokens[next])
            let lowered = word.lowercased()
            if word.isEmpty || notEntities.contains(lowered) { break }
            if fillers.contains(lowered), name.isEmpty {
                next += 1
                continue
            }
            if fillers.contains(lowered) || !(isCapitalised(word) || isCode(word)) { break }
            name.append(word)
            if endsSentence(tokens[next]) { break }
            next += 1
        }
        return name
    }

    private static func trimmed(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "-_")))
    }

    private static func endsSentence(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        return ".!?".contains(last)
    }

    private static func isCapitalised(_ word: String) -> Bool {
        guard word.count >= 3, let first = word.first, first.isUppercase else { return false }
        return !word.contains(where: \.isNumber)
    }

    private static func isCode(_ word: String) -> Bool {
        let digits = word.filter(\.isNumber).count
        guard digits > 0, !word.hasPrefix("-") else { return false }
        return digits >= 4 || (word.contains(where: \.isLetter) && word.count >= 3)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && !$0.hasPrefix("-") && seen.insert(key($0)).inserted }
    }
}

public struct LookupGate: Sendable {
    public static let defaultInterval = 20.0
    public static let perRound = 2
    public static let perMeeting = 40

    public var minimumInterval: Double
    private var asked: Set<String> = []
    private var lastAt: Double?

    public init(minimumInterval: Double = defaultInterval) {
        self.minimumInterval = minimumInterval
    }

    public mutating func pick(from candidates: [String], at now: Double) -> [String] {
        if let lastAt, now - lastAt < minimumInterval { return [] }
        var picked: [String] = []
        for candidate in candidates where picked.count < Self.perRound && asked.count + picked.count < Self.perMeeting {
            let key = EntityDetector.key(candidate)
            guard !asked.contains(key), !picked.contains(where: { EntityDetector.key($0) == key }) else { continue }
            picked.append(candidate)
        }
        guard !picked.isEmpty else { return [] }
        picked.forEach { asked.insert(EntityDetector.key($0)) }
        lastAt = now
        return picked
    }
}
