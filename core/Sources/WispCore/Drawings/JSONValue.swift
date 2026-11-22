import Foundation

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSONValue

        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    public static func int(_ value: Int) -> JSONValue { .number(String(value)) }

    public static func double(_ value: Double) -> JSONValue {
        if value == value.rounded(), abs(value) < 1e15 { return .number(String(Int(value))) }
        return .number(String(value))
    }

    public subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first { $0.key == key }?.value
        }
        set {
            guard case .object(var members) = self else { return }
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[index].value = newValue } else { members.remove(at: index) }
            } else if let newValue {
                members.append(Member(key: key, value: newValue))
            }
            self = .object(members)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let raw) = self { return Double(raw) }
        return nil
    }

    public var intValue: Int? {
        guard case .number(let raw) = self else { return nil }
        if let value = Int(raw) { return value }
        return Double(raw).flatMap { Int(exactly: $0.rounded()) }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectMembers: [JSONMember]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

public typealias JSONMember = JSONValue.Member

public struct JSONParseError: Error, Equatable, CustomStringConvertible {
    public let offset: Int
    public let reason: String
    public var description: String { "JSON inválido na posição \(offset): \(reason)" }
}

extension JSONValue {
    public static func parse(_ text: String) throws -> JSONValue {
        var parser = JSONParser(units: Array(text.utf8))
        return try parser.parseDocument()
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(units: Array(data))
        return try parser.parseDocument()
    }
}

private struct JSONParser {
    let units: [UInt8]
    var index = 0

    init(units: [UInt8]) {
        self.units = units
        if units.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    }

    mutating func parseDocument() throws -> JSONValue {
        let value = try parseValue()
        skipWhitespace()
        if index != units.count { throw fail("conteúdo depois do valor") }
        return value
    }

    func fail(_ reason: String) -> JSONParseError { JSONParseError(offset: index, reason: reason) }

    mutating func skipWhitespace() {
        while index < units.count, [0x20, 0x09, 0x0A, 0x0D].contains(units[index]) { index += 1 }
    }

    mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard index < units.count else { throw fail("fim inesperado") }
        switch units[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func expect(_ word: String) throws {
        let bytes = Array(word.utf8)
        guard index + bytes.count <= units.count, Array(units[index..<index + bytes.count]) == bytes else { throw fail("esperava \(word)") }
        index += bytes.count
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = index
        while index < units.count, "+-0123456789.eE".utf8.contains(units[index]) { index += 1 }
        guard index > start, let raw = String(bytes: units[start..<index], encoding: .utf8), Double(raw) != nil else {
            index = start
            throw fail("número inválido")
        }
        return .number(raw)
    }

    mutating func parseObject() throws -> JSONValue {
        index += 1
        var members: [JSONMember] = []
        skipWhitespace()
        if index < units.count, units[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard index < units.count, units[index] == UInt8(ascii: "\"") else { throw fail("esperava uma chave") }
            let key = try parseString()
            skipWhitespace()
            guard index < units.count, units[index] == UInt8(ascii: ":") else { throw fail("esperava ':'") }
            index += 1
            members.append(JSONMember(key: key, value: try parseValue()))
            skipWhitespace()
            guard index < units.count else { throw fail("fim inesperado") }
            if units[index] == UInt8(ascii: ",") { index += 1; continue }
            if units[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            throw fail("esperava ',' ou '}'")
        }
    }

    mutating func parseArray() throws -> JSONValue {
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < units.count, units[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            items.append(try parseValue())
            skipWhitespace()
            guard index < units.count else { throw fail("fim inesperado") }
            if units[index] == UInt8(ascii: ",") { index += 1; continue }
            if units[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            throw fail("esperava ',' ou ']'")
        }
    }

    mutating func parseString() throws -> String {
        index += 1
        var bytes: [UInt8] = []
        var pendingHigh: UInt16?
        func flushHigh() {
            if pendingHigh != nil {
                bytes.append(contentsOf: Array("\u{FFFD}".utf8))
                pendingHigh = nil
            }
        }
        while index < units.count {
            let byte = units[index]
            if byte == UInt8(ascii: "\"") {
                flushHigh()
                index += 1
                return String(decoding: bytes, as: UTF8.self)
            }
            if byte != UInt8(ascii: "\\") {
                flushHigh()
                bytes.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < units.count else { break }
            let escape = units[index]
            index += 1
            if escape != UInt8(ascii: "u") { flushHigh() }
            switch escape {
            case UInt8(ascii: "\""): bytes.append(0x22)
            case UInt8(ascii: "\\"): bytes.append(0x5C)
            case UInt8(ascii: "/"): bytes.append(0x2F)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "u"):
                guard index + 4 <= units.count,
                      let hex = String(bytes: units[index..<index + 4], encoding: .utf8),
                      let code = UInt16(hex, radix: 16) else { throw fail("escape \\u inválido") }
                index += 4
                if (0xD800...0xDBFF).contains(code) {
                    flushHigh()
                    pendingHigh = code
                } else if (0xDC00...0xDFFF).contains(code), let high = pendingHigh {
                    pendingHigh = nil
                    bytes.append(contentsOf: Array(String(decoding: [high, code], as: UTF16.self).utf8))
                } else {
                    flushHigh()
                    let scalar = Unicode.Scalar(UInt32(code)) ?? "\u{FFFD}"
                    bytes.append(contentsOf: Array(String(Character(scalar)).utf8))
                }
            default: throw fail("escape inválido")
            }
        }
        throw fail("string sem fim")
    }
}

extension JSONValue {
    public func serialized(indent: String? = nil) -> String {
        var out = ""
        write(into: &out, indent: indent, depth: 0)
        return out
    }

    func write(into out: inout String, indent: String?, depth: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let raw): out += raw
        case .string(let value): Self.writeString(value, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (offset, item) in items.enumerated() {
                if offset > 0 { out += "," }
                Self.newline(&out, indent, depth + 1)
                item.write(into: &out, indent: indent, depth: depth + 1)
            }
            Self.newline(&out, indent, depth)
            out += "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{"
            for (offset, member) in members.enumerated() {
                if offset > 0 { out += "," }
                Self.newline(&out, indent, depth + 1)
                Self.writeString(member.key, into: &out)
                out += indent == nil ? ":" : ": "
                member.value.write(into: &out, indent: indent, depth: depth + 1)
            }
            Self.newline(&out, indent, depth)
            out += "}"
        }
    }

    private static func newline(_ out: inout String, _ indent: String?, _ depth: Int) {
        guard let indent else { return }
        out += "\n" + String(repeating: indent, count: depth)
    }

    private static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
