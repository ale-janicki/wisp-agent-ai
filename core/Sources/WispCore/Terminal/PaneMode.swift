import Foundation

public enum PaneMode: Equatable, Sendable {
    public enum GridReason: Equatable, Sendable {
        case alternateScreen
        case mouseTracking
        case allowlisted
        case plainShell
        case manual
    }

    case blocks
    case grid(GridReason)

    public var isGrid: Bool {
        if case .grid = self { return true }
        return false
    }
}

public enum PaneModeDecider {
    public static let defaultAllowlist: Set<String> = [
        "claude", "klaus", "ssh", "mosh", "docker", "kubectl", "tmux", "python", "python3", "node", "irb",
        "top", "htop", "btop", "less", "more", "man", "nano", "vim", "nvim", "vi", "emacs",
    ]

    private static let wrappers: Set<String> = ["sudo", "exec", "command"]
    private static let replNames: Set<String> = ["python", "python3", "node", "irb"]
    private static let notReplFlags: Set<String> = ["-c", "-m", "-e", "-p", "-V", "--version", "-h", "--help", "--eval", "--print", "--check"]

    public static func decide(altScreen: Bool, mouse: Bool = false, command: String? = nil, allowlist: Set<String> = []) -> PaneMode {
        if altScreen { return .grid(.alternateScreen) }
        if mouse { return .grid(.mouseTracking) }
        if let command, isInteractive(command: command, allowlist: allowlist) { return .grid(.allowlisted) }
        return .blocks
    }

    public static func isInteractive(command: String, allowlist: Set<String>) -> Bool {
        segments(of: command).contains { segment in
            !segment.pipedOut && isInteractive(segment: segment.text, allowlist: allowlist)
        }
    }

    private struct Segment {
        var text: String
        var pipedOut: Bool
    }

    private static func segments(of command: String) -> [Segment] {
        var result = [Segment]()
        var current = ""
        var quote: Character?
        var escaped = false
        let characters = Array(command)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if escaped {
                escaped = false
            } else if let open = quote {
                if character == open { quote = nil } else if character == "\\", open == "\"" { escaped = true }
            } else if character == "\\" {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == ";" || character == "&" || character == "|" || character == "\n" {
                let doubled = (character == "&" || character == "|") && index < characters.count && characters[index] == character
                if doubled { index += 1 }
                result.append(Segment(text: current, pipedOut: character == "|" && !doubled))
                current = ""
                continue
            }
            current.append(character)
        }
        result.append(Segment(text: current, pipedOut: false))
        return result
    }

    private static func isInteractive(segment: String, allowlist: Set<String>) -> Bool {
        var words = segment.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        while let word = words.first, isAssignment(word) { words.removeFirst() }
        while let word = words.first, wrappers.contains(word) {
            let wrapper = words.removeFirst()
            while let flag = words.first, flag.hasPrefix("-") {
                words.removeFirst()
                if wrapper == "sudo" {
                    if flag == "--" { break }
                    if sudoValueOptions.contains(flag), !words.isEmpty { words.removeFirst() }
                }
            }
            while let word = words.first, isAssignment(word) { words.removeFirst() }
        }
        guard let first = words.first else { return false }
        let name = String(first.split(separator: "/").last ?? Substring(first))
        guard allowlist.contains(name) else { return false }
        let args = Array(words.dropFirst())
        if isNonInteractiveInvocation(name: name, args: args) { return false }
        switch name {
        case "docker": return runsInteractively(args, subcommands: ["run", "exec"])
        case "kubectl": return runsInteractively(args, subcommands: ["exec"])
        case "ssh": return opensRemoteShell(args)
        case "tmux": return opensTmuxSession(args)
        case "top": return !hasFlagWithValue(args, "-l")
        case "man": return !args.contains { manLookupFlags.contains($0) }
        case _ where replNames.contains(name): return isRepl(args)
        default: return true
        }
    }

    private static let sudoValueOptions: Set<String> = [
        "-u", "-g", "-h", "-p", "-C", "-U", "-r", "-t", "-D",
        "--user", "--group", "--host", "--prompt", "--close-from", "--other-user", "--role", "--type", "--chdir",
    ]
    private static let informationFlags: Set<String> = ["--version", "-V", "--help", "-h"]
    private static let sshValueOptions = Set("bcDEeFIiJLlmOopQRSWw")
    private static let manLookupFlags: Set<String> = ["-k", "-f", "-w", "--apropos", "--whatis", "--where", "--path"]
    private static let tmuxSessionCommands: Set<String> = [
        "attach", "attach-session", "a", "at", "new", "new-session", "n", "new-s",
    ]

    private static func isNonInteractiveInvocation(name: String, args: [String]) -> Bool {
        if args.count == 1, let only = args.first {
            if informationFlags.contains(only) { return true }
            if only == "-v", name != "ssh", name != "tmux" { return true }
        }
        switch name {
        case "claude": return args.contains { $0 == "-p" || $0 == "--print" }
        case "emacs": return args.contains { $0 == "--batch" || $0 == "-batch" }
        default: return false
        }
    }

    private static func opensRemoteShell(_ args: [String]) -> Bool {
        var positional = 0
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg == "--" {
                positional += args.count - index
                break
            }
            if arg.hasPrefix("-"), arg.count > 1 {
                if let last = arg.last, arg.count == 2, sshValueOptions.contains(last) { index += 1 }
            } else {
                positional += 1
            }
        }
        return positional <= 1
    }

    private static func opensTmuxSession(_ args: [String]) -> Bool {
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            index += 1
            if ["-L", "-S", "-f", "-c", "-T"].contains(args[index - 1]) { index += 1 }
        }
        guard index < args.count else { return true }
        let sub = args[index]
        guard tmuxSessionCommands.contains(sub) else { return false }
        return !(sub.hasPrefix("n") && args[(index + 1)...].contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("d") })
    }

    private static func hasFlagWithValue(_ args: [String], _ flag: String) -> Bool {
        args.enumerated().contains { $0.element == flag && $0.offset + 1 < args.count }
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let key = word[..<equals]
        return key.first.map { $0.isLetter || $0 == "_" } == true && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func runsInteractively(_ args: [String], subcommands: Set<String>) -> Bool {
        guard let sub = args.first(where: { !$0.hasPrefix("-") }), subcommands.contains(sub) else { return false }
        var interactive = false
        var tty = false
        for arg in args {
            if arg == "--" { break }
            if arg == "--interactive" { interactive = true }
            if arg == "--tty" || arg == "--tty=true" { tty = true }
            if arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.dropFirst().allSatisfy(\.isLetter) {
                if arg.contains("i") { interactive = true }
                if arg.contains("t") { tty = true }
            }
        }
        return interactive && tty
    }

    private static func isRepl(_ args: [String]) -> Bool {
        !args.contains { !$0.hasPrefix("-") || notReplFlags.contains($0) }
    }
}
