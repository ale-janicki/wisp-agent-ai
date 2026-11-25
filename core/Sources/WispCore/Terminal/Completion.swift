import Foundation

public struct Completion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case dir, file, exec, builtin }

    public let insertText: String
    public let display: String
    public let kind: Kind
    public let replaceRange: Range<Int>

    public init(insertText: String, display: String, kind: Kind, replaceRange: Range<Int>) {
        self.insertText = insertText
        self.display = display
        self.kind = kind
        self.replaceRange = replaceRange
    }
}

public struct CompletionContext: Sendable {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let isDirectory: Bool
        public init(name: String, isDirectory: Bool) {
            self.name = name
            self.isDirectory = isDirectory
        }
    }

    public var cwd: String
    public var home: String
    public var list: @Sendable (String) -> [Entry]
    public var executables: @Sendable () -> [String]

    public init(
        cwd: String, home: String, list: @escaping @Sendable (String) -> [Entry], executables: @escaping @Sendable () -> [String]
    ) {
        self.cwd = cwd
        self.home = home
        self.list = list
        self.executables = executables
    }

    public static func live(cwd: String, home: String, path: @escaping @Sendable () -> String) -> CompletionContext {
        CompletionContext(
            cwd: cwd, home: home,
            list: { directory in
                let fm = FileManager.default
                guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
                return names.map { name in
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: (directory as NSString).appendingPathComponent(name), isDirectory: &isDir)
                    return Entry(name: name, isDirectory: isDir.boolValue)
                }
            },
            executables: { ExecutablesCache.shared.names(path: path()) })
    }

    public static func warmExecutables(path: String) {
        ExecutablesCache.shared.refresh(path: path)
    }
}

final class ExecutablesCache: @unchecked Sendable {
    static let shared = ExecutablesCache()

    private struct Folder {
        var modified: Date?
        var names: [String]
    }

    private let maxAge: TimeInterval
    private let scansInBackground: Bool
    private let lock = NSLock()
    private var path: String?
    private var found = [String]()
    private var scannedAt: Date?
    private var folders = [String: Folder]()
    private var scanning = false

    init(maxAge: TimeInterval = 30, scansInBackground: Bool = true) {
        self.maxAge = maxAge
        self.scansInBackground = scansInBackground
    }

    func names(path requested: String, now: Date = Date()) -> [String] {
        lock.lock()
        let fresh = path == requested && scannedAt.map { now.timeIntervalSince($0) < maxAge } == true
        let result = path == requested ? found : []
        let start = !fresh && !scanning && scansInBackground
        if start { scanning = true }
        lock.unlock()
        if start { DispatchQueue.global(qos: .utility).async { self.refresh(path: requested) } }
        return result
    }

    func refresh(path requested: String, now: Date = Date()) {
        lock.lock()
        scanning = true
        let known = folders
        lock.unlock()
        let fm = FileManager.default
        var current = [String: Folder]()
        var names = Set<String>()
        for directory in requested.split(separator: ":").map(String.init) where !directory.isEmpty && current[directory] == nil {
            let modified = (try? fm.attributesOfItem(atPath: directory))?[.modificationDate] as? Date
            if let old = known[directory], old.modified == modified, modified != nil {
                current[directory] = old
            } else {
                let listed = ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).filter {
                    fm.isExecutableFile(atPath: (directory as NSString).appendingPathComponent($0))
                }
                current[directory] = Folder(modified: modified, names: listed)
            }
            names.formUnion(current[directory]?.names ?? [])
        }
        lock.lock()
        folders = current
        path = requested
        found = Array(names)
        scannedAt = now
        scanning = false
        lock.unlock()
    }
}

public enum CompletionEngine {
    public static let builtins = [
        "alias", "bg", "bindkey", "builtin", "cd", "command", "declare", "dirs", "disown", "echo", "emulate", "eval", "exec", "exit",
        "export", "false", "fc", "fg", "functions", "hash", "history", "jobs", "kill", "let", "local", "popd", "print", "printf",
        "pushd", "pwd", "read", "readonly", "return", "set", "setopt", "shift", "source", "test", "time", "trap", "true", "type",
        "typeset", "ulimit", "umask", "unalias", "unset", "unsetopt", "wait", "whence", "which",
        "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select", "then", "until", "while",
    ]
    static let directoryOnly: Set<String> = ["cd", "pushd", "rmdir"]
    private static let specials = Set(" \t\n\\\"'()[]{}<>|;&$`*?!#^=")

    struct Token: Equatable {
        var range: Range<Int>
        var value: String
        var openQuote: Character?
        var isCommand: Bool
        var command: String?
        var pendingEscape = false
        var literalStart = false
    }

    static func token(in line: String, cursor: Int) -> Token {
        var offset = 0
        var start = 0
        var value = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        var literalStart = false
        var words = [String]()
        func begin(at position: Int) {
            if !inWord { inWord = true; start = position; literalStart = false }
        }
        for character in line {
            if offset >= cursor { break }
            if escaped {
                value.append(character)
                escaped = false
            } else if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    escaped = true
                } else {
                    value.append(character)
                }
            } else {
                switch character {
                case "\\":
                    begin(at: offset)
                    if value.isEmpty { literalStart = true }
                    escaped = true
                case "'", "\"":
                    begin(at: offset)
                    if value.isEmpty { literalStart = true }
                    quote = character
                case " ", "\t", "\n":
                    if inWord { words.append(value); value = ""; inWord = false }
                case "|", ";", "&":
                    inWord = false
                    value = ""
                    words = []
                default:
                    begin(at: offset)
                    value.append(character)
                }
            }
            offset += character.utf16.count
        }
        let end = min(offset, cursor)
        return Token(
            range: (inWord ? start : end)..<end, value: inWord ? value : "", openQuote: quote, isCommand: words.isEmpty,
            command: words.first, pendingEscape: escaped,
            literalStart: inWord && literalStart)
    }

    private static func wordEnd(in line: String, cursor: Int, from token: Token) -> Int {
        var offset = 0
        var quote = token.openQuote
        var escaped = token.pendingEscape
        for character in line {
            let next = offset + character.utf16.count
            defer { offset = next }
            if next <= cursor { continue }
            if escaped {
                escaped = false
            } else if let open = quote {
                if character == open { quote = nil } else if character == "\\", open == "\"" { escaped = true }
            } else if character == "\\" {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = character
            } else if " \t\n|;&()<>".contains(character) {
                return offset
            }
        }
        return max(offset, cursor)
    }

    public static func complete(line: String, cursor: Int, context: CompletionContext) -> [Completion] {
        let atCursor = token(in: line, cursor: cursor)
        let token = self.token(in: line, cursor: wordEnd(in: line, cursor: cursor, from: atCursor))
        let looksLikePath = token.value.contains("/") || (token.value.hasPrefix("~") && !token.literalStart) || token.value.hasPrefix(".")
        if token.isCommand, !looksLikePath { return commands(token, context: context) }
        return paths(token, context: context, directoriesOnly: token.command.map(directoryOnly.contains) ?? false)
    }

    public static func commonPrefix(_ completions: [Completion]) -> String {
        guard var prefix = completions.first?.insertText else { return "" }
        for completion in completions.dropFirst() {
            prefix = String(zip(prefix, completion.insertText).prefix { $0 == $1 }.map(\.0))
        }
        if prefix.hasSuffix(" "), !completions.allSatisfy({ $0.insertText == prefix }) { prefix.removeLast() }
        var slashes = 0
        for character in prefix.reversed() { if character == "\\" { slashes += 1 } else { break } }
        if slashes % 2 == 1 { prefix.removeLast() }
        return prefix
    }

    // MARK: Commands

    private static func commands(_ token: Token, context: CompletionContext) -> [Completion] {
        guard !token.value.isEmpty else { return [] }
        let builtinSet = Set(builtins)
        return match(Array(builtinSet.union(context.executables())), prefix: token.value).map { name in
            Completion(
                insertText: wrap(escape(name), token: token, ending: " "), display: name,
                kind: builtinSet.contains(name) ? .builtin : .exec, replaceRange: token.range)
        }
    }

    // MARK: Paths

    private static func paths(_ token: Token, context: CompletionContext, directoriesOnly: Bool) -> [Completion] {
        let value = token.value
        if value == "~", token.openQuote == nil, !token.literalStart {
            return [Completion(insertText: "~/", display: "~/", kind: .dir, replaceRange: token.range)]
        }
        let split = value.lastIndex(of: "/").map { value.index(after: $0) } ?? value.startIndex
        let typedDirectory = String(value[..<split])
        let prefix = String(value[split...])
        var entries = context.list(resolve(typedDirectory, context: context))
        if prefix.hasPrefix(".") { entries.append(.init(name: "..", isDirectory: true)) }
        let visible = entries.filter { prefix.hasPrefix(".") || !$0.name.hasPrefix(".") }
        let isDirectory = Dictionary(visible.map { ($0.name, $0.isDirectory) }, uniquingKeysWith: { first, _ in first })
        return match(visible.map(\.name), prefix: prefix, kinds: isDirectory).compactMap { name in
            let dir = isDirectory[name] ?? false
            if directoriesOnly, !dir { return nil }
            let ending = dir ? "/" : " "
            let insert = token.openQuote == nil
                ? escapePath(typedDirectory) + escape(name, leadingTilde: typedDirectory.isEmpty) + ending
                : wrap(typedDirectory + name + (dir ? "/" : ""), token: token, ending: dir ? "" : " ")
            return Completion(insertText: insert, display: name + (dir ? "/" : ""), kind: dir ? .dir : .file, replaceRange: token.range)
        }
    }

    private static func resolve(_ typed: String, context: CompletionContext) -> String {
        if typed.isEmpty { return context.cwd }
        let expanded = typed.hasPrefix("~/") ? context.home + typed.dropFirst() : typed
        let absolute = expanded.hasPrefix("/") ? expanded : (context.cwd as NSString).appendingPathComponent(expanded)
        return (absolute as NSString).standardizingPath
    }

    // MARK: Matching and escaping

    private static func match(_ names: [String], prefix: String, kinds: [String: Bool]? = nil) -> [String] {
        var found = names.filter { $0.hasPrefix(prefix) }
        if found.isEmpty { found = names.filter { $0.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil } }
        return found.sorted { a, b in
            if let kinds, kinds[a] != kinds[b] { return kinds[a] == true }
            let order = a.localizedCaseInsensitiveCompare(b)
            return order == .orderedSame ? a < b : order == .orderedAscending
        }
    }

    static func escape(_ name: String, leadingTilde: Bool = false) -> String {
        var out = leadingTilde && name.hasPrefix("~") ? "\\" : ""
        for character in name {
            if specials.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    private static func escapePath(_ typed: String) -> String {
        typed.hasPrefix("~") ? "~" + escape(String(typed.dropFirst())) : escape(typed)
    }

    private static func wrap(_ text: String, token: Token, ending: String) -> String {
        guard let quote = token.openQuote else { return text + ending }
        return String(quote) + escapeInQuote(text, quote: quote) + (ending.isEmpty ? "" : String(quote) + ending)
    }

    static func escapeInQuote(_ text: String, quote: Character) -> String {
        if quote == "'" { return text.replacingOccurrences(of: "'", with: "'\\''") }
        var out = ""
        for character in text {
            if "\"$`\\".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
