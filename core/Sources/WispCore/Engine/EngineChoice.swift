import Foundation

public enum EngineChoice {
    public static func modelosURL(wispDir: URL) -> URL {
        wispDir.appendingPathComponent("modelos.toml")
    }

    public static func parseActive(_ text: String) -> String? {
        topLevelString(text, key: "ativo")
    }

    public static func topLevelString(_ text: String, key: String) -> String? {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            guard line.hasPrefix(key) else { continue }
            let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\""), let close = value.dropFirst().firstIndex(of: "\"") else { return nil }
            let name = String(value[value.index(after: value.startIndex)..<close])
            return name.isEmpty ? nil : name
        }
        return nil
    }

    public static func active(
        wispDir: URL = WispFolder.directory(), fileManager: FileManager = .default
    ) -> EngineKind {
        guard let data = fileManager.contents(atPath: modelosURL(wispDir: wispDir).path),
              let name = parseActive(String(decoding: data, as: UTF8.self)),
              let kind = EngineKind(rawValue: name) else { return .claude }
        return kind
    }
}
