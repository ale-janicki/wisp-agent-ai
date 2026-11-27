import Foundation

public struct GitStatus: Equatable, Sendable {
    public var branch: String
    public var changedFiles: Int
    public var insertions: Int
    public var deletions: Int

    public init(branch: String, changedFiles: Int = 0, insertions: Int = 0, deletions: Int = 0) {
        self.branch = branch
        self.changedFiles = changedFiles
        self.insertions = insertions
        self.deletions = deletions
    }

    public var isDirty: Bool { changedFiles > 0 }
    public var isDefaultBranch: Bool { branch == "main" || branch == "master" }

    public static func parse(porcelain: String, shortstat: String) -> GitStatus? {
        guard let branch = branchName(porcelain) else { return nil }
        let stat = parseShortstat(shortstat)
        return GitStatus(branch: branch, changedFiles: changedCount(porcelain), insertions: stat.insertions, deletions: stat.deletions)
    }

    static func branchName(_ porcelain: String) -> String? {
        var head: String?
        var oid: String?
        for line in porcelain.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") { head = String(line.dropFirst("# branch.head ".count)) }
            if line.hasPrefix("# branch.oid ") { oid = String(line.dropFirst("# branch.oid ".count)) }
        }
        guard let head else { return nil }
        guard head == "(detached)" else { return head }
        guard let oid, oid != "(initial)" else { return nil }
        return String(oid.prefix(7))
    }

    static func changedCount(_ porcelain: String) -> Int {
        porcelain.split(separator: "\n").filter { line in
            guard let first = line.first, line.dropFirst().first == " " else { return false }
            return "12u?".contains(first)
        }.count
    }

    static func parseShortstat(_ text: String) -> (insertions: Int, deletions: Int) {
        var insertions = 0
        var deletions = 0
        for part in text.split(separator: ",") {
            let words = part.split(separator: " ")
            guard let first = words.first, let value = Int(first), words.count > 1 else { continue }
            if words[1].hasPrefix("insertion") { insertions = value }
            if words[1].hasPrefix("deletion") { deletions = value }
        }
        return (insertions, deletions)
    }
}

public enum ContextChips {
    public static func directoryLabel(_ path: String, home: String?) -> String {
        let shown = TerminalDirectory.abbreviated(path, home: home)
        let parts = shown.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 2, let last = parts.last, let root = parts.first else { return shown }
        return (shown.hasPrefix("/") ? "/" : root + "/") + "…/" + last
    }

    public static func lastFinishedID(_ blocks: [TerminalBlock]) -> Int? {
        blocks.last(where: { !$0.isRunning })?.id
    }
}
