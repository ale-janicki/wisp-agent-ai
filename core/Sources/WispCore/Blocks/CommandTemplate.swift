import Foundation

public enum CommandTemplate {
    public static func fill(_ template: String, _ values: [String: String]) -> String {
        fill(template, values, raw: [:])
    }

    /// One pass over the template: `{key}` from `values` goes in shell-quoted, from `raw` as is (the caller
    /// already quoted every piece). A value that itself holds `{other}` is never expanded again.
    public static func fill(_ template: String, _ values: [String: String], raw: [String: String]) -> String {
        var out = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let key = String(rest[rest.index(after: open)..<close])
            if let value = values[key] {
                out += quote(value)
            } else if let value = raw[key] {
                out += value
            } else {
                out += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    /// `--flag 'a' --flag 'b'`, or "" for no values.
    public static func repeated(_ flag: String, _ values: [String]) -> String {
        values.map { "\(flag) \(quote($0))" }.joined(separator: " ")
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
