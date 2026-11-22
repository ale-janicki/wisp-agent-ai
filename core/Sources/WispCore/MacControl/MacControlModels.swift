import Foundation

public struct MacOutcome: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public struct MacError: Error, Equatable, Sendable {
    public static let usage: Int32 = 2
    public static let permission: Int32 = 3
    public static let timeout: Int32 = 4
    public static let blocked: Int32 = 5
    public static let refused: Int32 = 6

    public let message: String
    public let exitCode: Int32

    public init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }

    public static let noAccessibility = MacError(
        "sem permissão de Acessibilidade: abra o Wisp, vá em Ajustes > Controle do Mac e permita o Wisp em Ajustes do Sistema > Privacidade e Segurança > Acessibilidade",
        exitCode: permission)
}

public struct MacElement: Equatable, Sendable {
    public var role: String
    public var subrole: String
    public var title: String
    public var detail: String
    public var value: String
    public var help: String
    public var identifier: String
    public var pressable: Bool
    public var editable: Bool
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var depth: Int

    public init(role: String, subrole: String = "", title: String = "", detail: String = "", value: String = "",
                help: String = "", identifier: String = "", pressable: Bool = false, editable: Bool = false, x: Int = 0, y: Int = 0, width: Int = 0, height: Int = 0, depth: Int = 0) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.detail = detail
        self.value = value
        self.help = help
        self.identifier = identifier
        self.pressable = pressable
        self.editable = editable
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.depth = depth
    }

    public var isSecure: Bool { MacSafety.isSecure(role: role, subrole: subrole) }
    public var label: String { title.isEmpty ? detail : title }
    public var centerX: Int { x + width / 2 }
    public var centerY: Int { y + height / 2 }
}

public enum MacSafety {
    public static let secureSubrole = "AXSecureTextField"

    public static func isSecure(role: String, subrole: String) -> Bool {
        subrole == secureSubrole || role == secureSubrole
    }

    public static func normalized(_ text: String) -> String {
        var out = ""
        var previous: Character?
        for character in text {
            if let previous, previous.isLowercase, character.isUppercase { out.append(" ") }
            out.append("_-.".contains(character) ? " " : character)
            previous = character
        }
        return out
    }

    public static func blocks(_ element: MacElement, pattern: String?) -> Bool {
        guard let pattern, !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return [element.title, element.detail, element.help, element.identifier].contains { text in
            guard !text.isEmpty else { return false }
            return [text, normalized(text)].contains { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }
    }

    public static let cardRoles: Set<String> = ["AXButton", "AXMenuItem", "AXMenuButton", "AXDefaultButton"]

    public static let navigationRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXTab", "AXTabGroup", "AXDisclosureTriangle", "AXScrollBar", "AXScrollArea",
        "AXStaticText", "AXLink", "AXRow", "AXCell", "AXOutline", "AXTable", "AXList", "AXGroup", "AXToolbar", "AXWindow", "AXSplitGroup",
        "AXSplitter", "AXRadioButton", "AXRadioGroup", "AXMenuBarItem", "AXMenuBar", "AXMenu", "AXWebArea", "AXSlider", "AXValueIndicator",
    ]

    static func asksCard(_ element: MacElement, ancestors: [MacElement]) -> Bool {
        guard cardRoles.contains(element.role) || (element.pressable && !navigationRoles.contains(element.role)) else { return false }
        if !element.label.isEmpty, ancestors.prefix(ancestorLimit).contains(where: { $0.role == "AXToolbar" }) { return false }
        return true
    }

    public static func requiresCard(_ element: MacElement, ancestors: [MacElement], strict: Bool) -> Bool {
        guard strict else { return false }
        let chain = Array(ancestors.prefix(ancestorLimit))
        if asksCard(element, ancestors: chain) { return true }
        return chain.indices.contains { asksCard(chain[$0], ancestors: Array(chain.dropFirst($0 + 1))) && chain[$0].role != "AXToolbar" }
    }

    public static let ancestorLimit = 3

    public static func blocks(_ element: MacElement, ancestors: [MacElement], pattern: String?) -> Bool {
        ([element] + ancestors.prefix(ancestorLimit)).contains { blocks($0, pattern: pattern) }
    }

    public static func ancestors(of index: Int, in elements: [MacElement]) -> [MacElement] {
        var out: [MacElement] = []
        var depth = elements[index].depth
        var cursor = index - 1
        while cursor >= 0, out.count < ancestorLimit, depth > 0 {
            if elements[cursor].depth < depth {
                out.append(elements[cursor])
                depth = elements[cursor].depth
            }
            cursor -= 1
        }
        return out
    }
}

public enum MacTree {
    public static let valueLimit = 80
    public static let defaultMax = 400
    public static let defaultDepth = 8

    public static func quoted(_ text: String, limit: Int, full: Bool = false) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: full ? "\\n" : " ")
        if full { return "\"" + flat.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let plain = flat.replacingOccurrences(of: "\"", with: "'")
        return plain.count > limit ? "\"" + plain.prefix(limit) + "…\"" : "\"" + plain + "\""
    }

    public static func line(_ element: MacElement, index: Int, full: Bool = false) -> String {
        var parts = [String(repeating: " ", count: element.depth) + "[\(index)] " + element.role]
        if !element.subrole.isEmpty { parts[0] += "/" + element.subrole }
        if !element.title.isEmpty { parts.append(quoted(element.title, limit: 120)) }
        if !element.detail.isEmpty, element.detail != element.title { parts.append("desc=" + quoted(element.detail, limit: 120)) }
        if element.isSecure {
            parts.append("value=<oculto>")
        } else if !element.value.isEmpty {
            parts.append("value=" + quoted(element.value, limit: valueLimit, full: full))
        }
        if element.width > 0 || element.height > 0 { parts.append("@\(element.x),\(element.y) \(element.width)x\(element.height)") }
        return parts.joined(separator: " ")
    }

    public static func render(_ elements: [MacElement], full: Bool = false) -> String {
        elements.enumerated().map { line($1, index: $0, full: full) }.joined(separator: "\n")
    }
}

public enum MacMatch {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    public static func indexes(in elements: [MacElement], title: String?, regex: String?, role: String?) -> [Int] {
        let wanted = title.map(fold)
        let pattern = regex.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        if regex != nil, pattern == nil { return [] }
        let candidates = elements.indices.filter { index in
            let element = elements[index]
            if let role, element.role != role { return false }
            if wanted == nil, pattern == nil { return role != nil }
            return [element.title, element.detail].contains { !$0.isEmpty && matches($0, wanted, pattern) }
        }
        guard let wanted else { return candidates }
        let exact = candidates.filter { [elements[$0].title, elements[$0].detail].contains { fold($0) == wanted } }
        return exact.isEmpty ? candidates : exact + candidates.filter { !exact.contains($0) }
    }

    private static func matches(_ text: String, _ wanted: String?, _ pattern: NSRegularExpression?) -> Bool {
        if let wanted { return fold(text).contains(wanted) }
        guard let pattern else { return false }
        return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

public struct MacKeyCombo: Equatable, Sendable {
    public let keyCode: UInt16
    public let command: Bool
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let function: Bool

    static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111,
    ]

    struct Flags { var command = false, shift = false, option = false, control = false, function = false }

    public static func parse(_ text: String) throws -> MacKeyCombo {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let tokens = text.trimmingCharacters(in: .whitespaces) == "+" ? ["+"] : parts
        guard let last = tokens.last, !last.isEmpty else { throw MacError("tecla inválida: \(text)", exitCode: MacError.usage) }
        var flags = Flags()
        for name in tokens.dropLast() {
            switch name {
            case "cmd", "command": flags.command = true
            case "shift": flags.shift = true
            case "opt", "option", "alt": flags.option = true
            case "ctrl", "control": flags.control = true
            case "fn": flags.function = true
            default: throw MacError("modificador desconhecido: \(name)", exitCode: MacError.usage)
            }
        }
        guard let code = codes[last] else { throw MacError("tecla desconhecida: \(last)", exitCode: MacError.usage) }
        return MacKeyCombo(keyCode: code, command: flags.command, shift: flags.shift, option: flags.option,
                           control: flags.control, function: flags.function)
    }
}

public enum MacPoint {
    public static func parse(_ text: String) throws -> (x: Int, y: Int) {
        let parts = text.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let x = parts[0], let y = parts[1] else {
            throw MacError("ponto inválido (use x,y): \(text)", exitCode: MacError.usage)
        }
        return (x, y)
    }
}

public enum MacMenuPath {
    public static func parse(_ text: String) throws -> [String] {
        let parts = text.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts.contains(where: \.isEmpty) else {
            throw MacError("caminho de menu inválido (use \"Arquivo > Salvar\"): \(text)", exitCode: MacError.usage)
        }
        return parts
    }
}

public struct MacCompose: Equatable, Sendable {
    public let body: String
    public let recipients: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String
    public let window: String

    static let bodyRoles: Set<String> = ["AXTextArea", "AXWebArea"]
    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXTokenField", "AXWebArea"]
    static let toPattern = "^\\s*(to|para|recipients?|destinat[aá]rios?)\\s*:?\\s*$"
    static let ccPattern = "^\\s*(cc|c\\.c\\.|c[oó]pia)\\s*:?\\s*$"
    static let bccPattern = "^\\s*(bcc|cco|c[oó]pia oculta|blind copy)\\s*:?\\s*$"
    static let subjectPattern = "^\\s*(subject|assunto)\\s*:?\\s*$"

    public static func canon(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard !text.isEmpty, let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func labelled(_ elements: [MacElement], _ pattern: String) -> [String] {
        var out: [String] = []
        for (index, element) in elements.enumerated() where matches(pattern, element.title) || matches(pattern, element.detail) {
            var values = [element.value]
            var cursor = index + 1
            while cursor < elements.count, elements[cursor].depth > element.depth {
                values += [elements[cursor].value, elements[cursor].title]
                cursor += 1
            }
            if values.allSatisfy({ $0.isEmpty }) {
                if let next = elements[(index + 1)...].prefix(3).first(where: { textRoles.contains($0.role) }) {
                    values = [next.value]
                    var inner = elements.firstIndex(of: next).map { $0 + 1 } ?? elements.count
                    while inner < elements.count, elements[inner].depth > next.depth {
                        values += [elements[inner].value, elements[inner].title]
                        inner += 1
                    }
                }
            }
            out += values
        }
        return out
    }

    static func names(_ elements: [MacElement], _ pattern: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;\n")
        var seen: [String] = []
        for raw in labelled(elements, pattern) {
            for part in raw.components(separatedBy: separators) {
                let name = part.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !seen.contains(name) { seen.append(name) }
            }
        }
        return seen
    }

    public static func extract(elements: [MacElement], window: String) -> MacCompose {
        let candidates = elements.filter { bodyRoles.contains($0.role) && !$0.isSecure && $0.editable }
        let main = candidates.max { $0.width * $0.height < $1.width * $1.height }
        let subject = labelled(elements, subjectPattern).first { !$0.isEmpty } ?? ""
        return MacCompose(body: main?.value ?? "", recipients: names(elements, toPattern), cc: names(elements, ccPattern),
                          bcc: names(elements, bccPattern), subject: subject, window: window)
    }
}

public enum MacCaller {
    public static let minimumLength = 32
    public static let maximumLength = 128

    public static func isWispRuntime(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        return path.contains("/wisp/runtime/") || path.contains("/Wisp.app/Contents/")
    }

    public static func valid(nonce: String?, directory: URL, uid: uid_t = getuid(), fileManager: FileManager = .default,
                             processCheck: (pid_t) -> Bool = MacCaller.isWispRuntime) -> Bool {
        guard let nonce = nonce?.trimmingCharacters(in: .whitespacesAndNewlines), nonce.count >= minimumLength, nonce.count <= maximumLength,
              nonce.allSatisfy({ $0.isHexDigit }) else { return false }
        let path = directory.appendingPathComponent(nonce).path
        var info = Darwin.stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == uid, info.st_mode & 0o077 == 0 else { return false }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, kill(pid, 0) == 0 else { return false }
        return processCheck(pid)
    }

    public static func readLine(from descriptor: Int32, timeout: Int32 = 2000) -> String? {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, timeout) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: maximumLength + 2)
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    public static let refusal = "recusei: o ajudante só age quando chamado pelo servidor de controle do Mac do Wisp (use `wisp mac ...` ou as ferramentas mac_*)"
    public static let freeCommands: Set<String> = ["permissao", "selftest"]
}
