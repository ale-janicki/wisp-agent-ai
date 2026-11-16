import Foundation

public enum CommandTemplate {
    public static func fill(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { command, pair in
            command.replacingOccurrences(of: "{\(pair.key)}", with: quote(pair.value))
        }
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
