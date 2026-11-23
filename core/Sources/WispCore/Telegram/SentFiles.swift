import Foundation

public enum SentFiles {
    private static let valueFlags: Set<String> = ["--thread", "--legenda"]
    private static let controlOperators: Set<String> = ["&&", "||", ";", "|", "&"]

    static func expandHome(_ word: String, home: String = NSHomeDirectory()) -> String {
        for prefix in ["~/", "$HOME/", "${HOME}/"] where word.hasPrefix(prefix) {
            return home + "/" + word.dropFirst(prefix.count)
        }
        return word
    }

    public static func enviarFiles(in command: String, exists: (String) -> Bool = regularFileExists) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for segment in segments(of: shellWords(command)) {
            var words = segment[...]
            while let first = words.first, isAssignment(first) { words = words.dropFirst() }
            guard let binary = words.first, isWispBinary(binary),
                  words.count >= 3, words[words.startIndex + 1] == "topic", words[words.startIndex + 2] == "enviar" else { continue }
            var index = words.startIndex + 3
            while index < words.endIndex {
                let word = words[index]
                index += 1
                if word.hasPrefix("-") {
                    if valueFlags.contains(word), index < words.endIndex { index += 1 }
                    continue
                }
                let path = expandHome(word)
                if path.hasPrefix("/"), exists(path), seen.insert(path).inserted { out.append(path) }
            }
        }
        return out
    }

    private static func segments(of words: [String]) -> [[String]] {
        var out: [[String]] = [[]]
        for word in words {
            if controlOperators.contains(word) { out.append([]) } else { out[out.count - 1].append(word) }
        }
        return out.filter { !$0.isEmpty }
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func isWispBinary(_ word: String) -> Bool {
        ["$WISP_BIN", "${WISP_BIN}"].contains(word) || word == "wisp" || word.hasSuffix("/wisp")
    }

    public static func cards(sent: [String], replyText: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for path in sent + FileLinks.absolutePaths(in: replyText) where seen.insert(path).inserted { out.append(path) }
        return out
    }

    public static func unsent(_ candidates: [String], alreadySent: [String]) -> [String] {
        func key(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
        var seen = Set(alreadySent.map(key))
        var out: [String] = []
        for path in candidates where seen.insert(key(path)).inserted {
            out.append(path)
            if out.count == FileLinks.maxFiles { break }
        }
        return out
    }

    public static func isImage(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    public static func regularFileExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    static func shellWords(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        var escaped = false
        func flush() {
            if started { words.append(current) }
            current = ""
            started = false
        }
        for char in command {
            if escaped {
                current.append(char)
                escaped = false
            } else if let open = quote {
                if char == open { quote = nil }
                else if char == "\\", open == "\"" { escaped = true }
                else { current.append(char) }
            } else if char == "\\" {
                escaped = true
                started = true
            } else if char == "'" || char == "\"" {
                quote = char
                started = true
            } else if char == " " || char == "\t" || char == "\n" {
                flush()
            } else if char == ";" || char == "|" || char == "&" {
                flush()
                if let last = words.last, last == String(char), char != ";" { words[words.count - 1] = last + String(char) }
                else { words.append(String(char)) }
            } else {
                current.append(char)
                started = true
            }
        }
        flush()
        return words
    }
}

public enum ToolBlock {
    public static let prefix = "wisp-guard:"

    public static func hookReason(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: prefix) else { continue }
            let reason = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return reason.isEmpty ? "bloqueado" : String(reason.prefix(160))
        }
        return nil
    }

    public static func notice(reason: String) -> String {
        let text = reason.lowercased()
        func has(_ parts: String...) -> Bool { parts.contains { text.contains($0) } }
        if has("hook guard-") && has(" failed") {
            return "Uma trava do Wisp falhou ao conferir um comando, então ele foi barrado por segurança."
        }
        if has("wisp-mac helper", "osascript", "system events", "sending mail from a script", "email server", "wisp_approval_socket") {
            return "O Wisp tentou um atalho que pularia a tua aprovação para enviar algo. A trava barrou, e ele segue pelo caminho que pede o teu ok."
        }
        if has("files reach the user only through wisp") {
            return "O Wisp tentou te mandar um arquivo por fora do app. A trava barrou, e o arquivo vai pelo Wisp."
        }
        if has("calendar or reminders") {
            return "O Wisp tentou mudar a tua Agenda ou os Lembretes por fora. A trava barrou, e ele segue pelo caminho que pede o teu ok."
        }
        if has("could destroy") {
            return "O Wisp tentou um comando que poderia apagar dados ou mexer no Mac sem volta. A trava barrou."
        }
        if has("secrets folder", "token and config") {
            return "O Wisp tentou abrir a pasta de segredos do Wisp. A trava barrou."
        }
        if has("learned-lessons") {
            return "O Wisp tentou mudar as lições aprendidas, que só tu alteras. A trava barrou."
        }
        if has("brain harvest") {
            return "A coleta do brain tentou mexer fora da pasta do brain. A trava barrou."
        }
        return "A trava do Wisp barrou um comando."
    }
}
