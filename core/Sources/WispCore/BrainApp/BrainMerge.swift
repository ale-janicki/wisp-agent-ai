import Foundation

public enum BrainMerge {
    public enum Outcome: Sendable, Equatable {
        case unchanged
        case reload(String)
        case merged(String)
        case conflict(String)
    }

    public static let mineMarker = "<<<<<<< minhas edições"
    public static let divider = "======="
    public static let theirsMarker = ">>>>>>> no disco"
    public static func hasMarkers(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { $0 == Substring(mineMarker) } && lines.contains { $0 == Substring(theirsMarker) }
    }

    static let cellLimit = 4_000_000

    public static func merge(base: String, mine: String, theirs: String) -> Outcome {
        if theirs == base || theirs == mine { return .unchanged }
        if mine == base { return .reload(theirs) }
        let baseLines = lines(base), mineLines = lines(mine), theirLines = lines(theirs)
        let matchMine = matches(baseLines, mineLines), matchTheirs = matches(baseLines, theirLines)
        var out: [String] = []
        var conflicted = false
        var previous = (base: -1, mine: -1, theirs: -1)

        func chunk(upToBase i: Int, mine mi: Int, theirs ti: Int) {
            let originalPart = Array(baseLines[(previous.base + 1)..<i])
            let minePart = Array(mineLines[(previous.mine + 1)..<mi])
            let theirPart = Array(theirLines[(previous.theirs + 1)..<ti])
            if minePart == originalPart {
                out += theirPart
            } else if theirPart == originalPart || theirPart == minePart {
                out += minePart
            } else {
                conflicted = true
                out += [mineMarker] + minePart + [divider] + theirPart + [theirsMarker]
            }
        }

        for i in baseLines.indices {
            guard let mi = matchMine[i], let ti = matchTheirs[i] else { continue }
            chunk(upToBase: i, mine: mi, theirs: ti)
            out.append(baseLines[i])
            previous = (i, mi, ti)
        }
        chunk(upToBase: baseLines.count, mine: mineLines.count, theirs: theirLines.count)
        let text = out.joined(separator: "\n")
        return conflicted ? .conflict(text) : .merged(text)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func matches(_ a: [String], _ b: [String]) -> [Int?] {
        var result = [Int?](repeating: nil, count: a.count)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
            result[prefix] = prefix
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            result[a.count - 1 - suffix] = b.count - 1 - suffix
            suffix += 1
        }
        let n = a.count - prefix - suffix, m = b.count - prefix - suffix
        guard n > 0, m > 0, (n + 1) * (m + 1) <= cellLimit else { return result }
        var ids: [String: Int32] = [:]
        func intern(_ line: String) -> Int32 {
            if let id = ids[line] { return id }
            let id = Int32(ids.count)
            ids[line] = id
            return id
        }
        let left = a[prefix..<(prefix + n)].map(intern)
        let right = b[prefix..<(prefix + m)].map(intern)
        var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        let width = m + 1
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = left[i] == right[j] ? table[(i + 1) * width + j + 1] + 1 : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var i = 0, j = 0
        while i < n, j < m {
            if left[i] == right[j] {
                result[prefix + i] = prefix + j
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}
