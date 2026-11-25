import Foundation

public struct BlockSelection: Equatable, Sendable {
    public private(set) var ids = Set<Int>()
    public private(set) var anchor: Int?
    public private(set) var cursor: Int?

    public init() {}

    public var isEmpty: Bool { ids.isEmpty }

    public func contains(_ id: Int) -> Bool { ids.contains(id) }

    public func ordered(in order: [Int]) -> [Int] { order.filter(ids.contains) }

    public mutating func clear() {
        ids = []
        anchor = nil
        cursor = nil
    }

    public mutating func select(_ id: Int) {
        ids = [id]
        anchor = id
        cursor = id
    }

    public mutating func toggle(_ id: Int) {
        if ids.remove(id) == nil { ids.insert(id) }
        anchor = id
        cursor = id
    }

    public mutating func selectRange(to id: Int, in order: [Int]) {
        guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
            select(id)
            return
        }
        ids = Set(order[min(from, to)...max(from, to)])
        cursor = id
    }

    @discardableResult
    public mutating func move(_ delta: Int, extend: Bool, in order: [Int]) -> Int? {
        guard !order.isEmpty else {
            clear()
            return nil
        }
        guard let current = cursor.flatMap(order.firstIndex(of:)) else {
            guard delta < 0, let last = order.last else { return nil }
            select(last)
            return last
        }
        let target = min(order.count - 1, max(0, current + (delta < 0 ? -1 : 1)))
        let id = order[target]
        if extend {
            selectRange(to: id, in: order)
        } else {
            select(id)
        }
        return id
    }

    public mutating func prune(to order: [Int]) {
        let present = Set(order)
        ids.formIntersection(present)
        if let anchor, !present.contains(anchor) { self.anchor = ids.first }
        if let cursor, !present.contains(cursor) { self.cursor = anchor }
        if ids.isEmpty { clear() }
    }
}

public struct BlockMatch: Equatable, Sendable {
    public enum Field: Equatable, Sendable { case command, output }

    public var blockID: Int
    public var field: Field
    public var range: Range<Int>
}

public enum BlockSearch {
    public static func matches(
        for query: String, in blocks: [(id: Int, command: String, output: String)], limitPerField: Int = 5_000
    ) -> [BlockMatch] {
        guard !query.isEmpty else { return [] }
        var result = [BlockMatch]()
        for block in blocks {
            result += ranges(of: query, in: block.command, limit: limitPerField).map {
                BlockMatch(blockID: block.id, field: .command, range: $0)
            }
            result += ranges(of: query, in: block.output, limit: limitPerField).map {
                BlockMatch(blockID: block.id, field: .output, range: $0)
            }
        }
        return result
    }

    private static func ranges(of query: String, in text: String, limit: Int) -> [Range<Int>] {
        guard !text.isEmpty else { return [] }
        let haystack = text as NSString
        var found = [Range<Int>]()
        var from = 0
        while from < haystack.length, found.count < limit {
            let hit = haystack.range(
                of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: haystack.length - from))
            guard hit.location != NSNotFound, hit.length > 0 else { break }
            found.append(hit.location..<(hit.location + hit.length))
            from = hit.location + hit.length
        }
        return found
    }
}
