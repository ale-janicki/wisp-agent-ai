import Foundation

public struct LocalReadiness: Equatable, Sendable {
    public var ready: Bool
    public var missing: String?

    public init(ready: Bool, missing: String? = nil) {
        self.ready = ready
        self.missing = missing
    }

    public func note() -> String {
        "a IA local não está pronta (\(missing ?? "sem detalhe")); esta conversa roda no Claude. Ajustes > Modelo resolve."
    }

    public static func parse(_ data: Data) -> LocalReadiness? {
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "ready", let ready = object["ready"] as? Bool {
                return LocalReadiness(ready: ready, missing: object["missing"] as? String)
            }
            if type == "error" { return LocalReadiness(ready: false, missing: object["message"] as? String) }
        }
        return nil
    }

    public static func check(wispBinary: String?, environment: [String: String]) -> LocalReadiness {
        guard let wispBinary, !wispBinary.isEmpty else { return LocalReadiness(ready: false, missing: "não achei o comando do Wisp") }
        let result = CommandRunner.run(
            executable: URL(fileURLWithPath: wispBinary), arguments: ["local", "ready"], environment: environment, timeout: 45)
        guard case .success(let output) = result else { return LocalReadiness(ready: false, missing: "não consegui rodar o comando do Wisp") }
        if output.timedOut { return LocalReadiness(ready: false, missing: "o servidor local não respondeu a tempo") }
        return parse(output.stdout) ?? LocalReadiness(ready: false, missing: "não consegui conferir a IA local")
    }
}
