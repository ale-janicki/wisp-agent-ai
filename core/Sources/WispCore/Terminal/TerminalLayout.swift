import CoreGraphics
import Foundation

public struct TerminalLayout: Equatable, Sendable {
    public enum Axis: Equatable, Sendable {
        case horizontal
        case vertical
    }

    public enum Direction: Equatable, Sendable {
        case left, right, up, down
    }

    public indirect enum Node: Equatable, Sendable {
        case leaf(UUID)
        case split(Axis, ratio: Double, first: Node, second: Node)
    }

    public struct Tab: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var customTitle: String?
        public var root: Node
        public var focused: UUID
        public var maximized = false

        public init(id: UUID = UUID(), session: UUID) {
            self.id = id
            root = .leaf(session)
            focused = session
        }

        public var sessions: [UUID] { root.leaves }

        public func remapped(_ map: [UUID: UUID]) -> Tab {
            var tab = self
            tab.root = root.remapped(map)
            tab.focused = map[focused] ?? focused
            return tab
        }

        public var frames: [UUID: CGRect] {
            maximized ? [focused: Self.unit] : root.frames(in: Self.unit)
        }

        public var dividers: [Divider] {
            maximized ? [] : root.dividers(in: Self.unit, path: [])
        }

        static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    public struct Divider: Equatable, Sendable {
        public let path: [Int]
        public let axis: Axis
        public let ratio: Double
        public let bounds: CGRect

        public func ratio(at point: CGPoint) -> Double {
            switch axis {
            case .horizontal: bounds.width > 0 ? Double((point.x - bounds.minX) / bounds.width) : ratio
            case .vertical: bounds.height > 0 ? Double((point.y - bounds.minY) / bounds.height) : ratio
            }
        }
    }

    public enum Removal: Equatable, Sendable {
        case pane
        case tab
    }

    public static let ratioRange = 0.15...0.85

    public private(set) var tabs: [Tab] = []
    public private(set) var selectedTabID: UUID?

    public init() {}

    public var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }

    public var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedTabID } }

    public var focusedSession: UUID? { selectedTab?.focused }

    public func tabIndex(containing session: UUID) -> Int? {
        tabs.firstIndex { $0.root.contains(session) }
    }

    // MARK: Tabs

    public mutating func addTab(session: UUID, id: UUID = UUID()) {
        tabs.append(Tab(id: id, session: session))
        selectedTabID = id
    }

    @discardableResult
    public mutating func selectTab(_ id: UUID) -> Bool {
        guard tabs.contains(where: { $0.id == id }) else { return false }
        selectedTabID = id
        return true
    }

    @discardableResult
    public mutating func selectTab(at index: Int) -> Bool {
        guard tabs.indices.contains(index) else { return false }
        selectedTabID = tabs[index].id
        return true
    }

    @discardableResult
    public mutating func selectLastTab() -> Bool {
        guard let last = tabs.last else { return false }
        selectedTabID = last.id
        return true
    }

    @discardableResult
    public mutating func selectAdjacentTab(_ offset: Int) -> Bool {
        guard let index = selectedIndex, tabs.count > 1 else { return false }
        let count = tabs.count
        selectedTabID = tabs[((index + offset) % count + count) % count].id
        return true
    }

    public mutating func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), tabs.indices.contains(destination), source != destination else { return }
        tabs.insert(tabs.remove(at: source), at: destination)
    }

    @discardableResult
    public mutating func moveSelectedTab(_ offset: Int) -> Bool {
        guard let index = selectedIndex, tabs.indices.contains(index + offset), offset != 0 else { return false }
        moveTab(from: index, to: index + offset)
        return true
    }

    public mutating func insertTab(_ tab: Tab, at index: Int) {
        guard !tabs.contains(where: { $0.id == tab.id }) else { return }
        tabs.insert(tab, at: min(max(index, 0), tabs.count))
        selectedTabID = tab.id
    }

    public mutating func rename(_ id: UUID, to title: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        tabs[index].customTitle = trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    public mutating func closeTab(_ id: UUID) -> [UUID] {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return [] }
        let removed = tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        return removed.sessions
    }

    public mutating func removeAll() {
        tabs.removeAll()
        selectedTabID = nil
    }

    // MARK: Panes

    @discardableResult
    public mutating func focus(_ session: UUID) -> Bool {
        guard let index = tabIndex(containing: session) else { return false }
        selectedTabID = tabs[index].id
        if tabs[index].focused != session {
            tabs[index].focused = session
            tabs[index].maximized = false
        }
        return true
    }

    @discardableResult
    public mutating func split(_ axis: Axis, adding session: UUID) -> Bool {
        guard let index = selectedIndex, tabIndex(containing: session) == nil else { return false }
        let focused = tabs[index].focused
        tabs[index].root = tabs[index].root.replacing(focused, with: .split(axis, ratio: 0.5, first: .leaf(focused), second: .leaf(session)))
        tabs[index].focused = session
        tabs[index].maximized = false
        return true
    }

    @discardableResult
    public mutating func close(_ session: UUID) -> Removal? {
        guard let index = tabIndex(containing: session) else { return nil }
        guard let rest = tabs[index].root.removing(session) else {
            closeTab(tabs[index].id)
            return .tab
        }
        tabs[index].root = rest.node
        tabs[index].maximized = false
        if tabs[index].focused == session { tabs[index].focused = rest.heir }
        return .pane
    }

    @discardableResult
    public mutating func moveFocus(_ direction: Direction) -> Bool {
        guard let index = selectedIndex, !tabs[index].maximized else { return false }
        let tab = tabs[index]
        guard let next = Self.neighbour(of: tab.focused, toward: direction, in: tab.root.frames(in: Tab.unit)) else { return false }
        tabs[index].focused = next
        return true
    }

    @discardableResult
    public mutating func focusAdjacentPane(_ offset: Int) -> Bool {
        guard let index = selectedIndex, !tabs[index].maximized else { return false }
        let panes = tabs[index].sessions
        guard panes.count > 1, let at = panes.firstIndex(of: tabs[index].focused) else { return false }
        tabs[index].focused = panes[((at + offset) % panes.count + panes.count) % panes.count]
        return true
    }

    @discardableResult
    public mutating func resizeFocused(_ direction: Direction, step: Double = 0.05) -> Bool {
        guard let index = selectedIndex, !tabs[index].maximized else { return false }
        let axis: Axis = direction == .left || direction == .right ? .horizontal : .vertical
        guard let path = tabs[index].root.nearestSplit(on: axis, around: tabs[index].focused, path: []),
              let divider = tabs[index].dividers.first(where: { $0.path == path }) else { return false }
        resize(path, to: divider.ratio + (direction == .right || direction == .down ? step : -step))
        return true
    }

    @discardableResult
    public mutating func toggleMaximize() -> Bool {
        guard let index = selectedIndex else { return false }
        guard tabs[index].maximized || tabs[index].sessions.count > 1 else { return false }
        tabs[index].maximized.toggle()
        return true
    }

    public mutating func resize(_ path: [Int], to ratio: Double) {
        guard let index = selectedIndex, ratio.isFinite else { return }
        let clamped = min(max(ratio, Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
        tabs[index].root = tabs[index].root.setting(ratio: clamped, at: path[...])
    }

    public static func neighbour(of session: UUID, toward direction: Direction, in frames: [UUID: CGRect]) -> UUID? {
        guard let from = frames[session] else { return nil }
        let epsilon: CGFloat = 1e-6
        var best: (id: UUID, distance: CGFloat, centred: Bool, along: CGFloat)?
        for (id, rect) in frames where id != session {
            let distance: CGFloat
            let overlap: CGFloat
            let centred: Bool
            let along: CGFloat
            switch direction {
            case .right, .left:
                distance = direction == .right ? rect.minX - from.maxX : from.minX - rect.maxX
                overlap = min(rect.maxY, from.maxY) - max(rect.minY, from.minY)
                centred = rect.minY <= from.midY && from.midY < rect.maxY
                along = rect.minY
            case .down, .up:
                distance = direction == .down ? rect.minY - from.maxY : from.minY - rect.maxY
                overlap = min(rect.maxX, from.maxX) - max(rect.minX, from.minX)
                centred = rect.minX <= from.midX && from.midX < rect.maxX
                along = rect.minX
            }
            guard distance > -epsilon, overlap > epsilon else { continue }
            if let current = best {
                if distance > current.distance + epsilon { continue }
                if abs(distance - current.distance) <= epsilon {
                    if current.centred && !centred { continue }
                    if current.centred == centred && along >= current.along { continue }
                }
            }
            best = (id, distance, centred, along)
        }
        return best?.id
    }

    public static func matches(_ query: String, fields: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { word in
            fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

extension TerminalLayout.Node {
    public var leaves: [UUID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, _, let first, let second): first.leaves + second.leaves
        }
    }

    public func contains(_ session: UUID) -> Bool {
        switch self {
        case .leaf(let id): id == session
        case .split(_, _, let first, let second): first.contains(session) || second.contains(session)
        }
    }

    public func frames(in rect: CGRect) -> [UUID: CGRect] {
        switch self {
        case .leaf(let id):
            return [id: rect]
        case .split(let axis, let ratio, let first, let second):
            let (a, b) = Self.divide(rect, axis: axis, ratio: ratio)
            return first.frames(in: a).merging(second.frames(in: b)) { lhs, _ in lhs }
        }
    }

    func dividers(in rect: CGRect, path: [Int]) -> [TerminalLayout.Divider] {
        guard case .split(let axis, let ratio, let first, let second) = self else { return [] }
        let (a, b) = Self.divide(rect, axis: axis, ratio: ratio)
        return [TerminalLayout.Divider(path: path, axis: axis, ratio: ratio, bounds: rect)]
            + first.dividers(in: a, path: path + [0]) + second.dividers(in: b, path: path + [1])
    }

    static func divide(_ rect: CGRect, axis: TerminalLayout.Axis, ratio: Double) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let width = rect.width * CGFloat(ratio)
            return (CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                    CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height))
        case .vertical:
            let height = rect.height * CGFloat(ratio)
            return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height),
                    CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height))
        }
    }

    func remapped(_ map: [UUID: UUID]) -> Self {
        switch self {
        case .leaf(let id): .leaf(map[id] ?? id)
        case .split(let axis, let ratio, let first, let second):
            .split(axis, ratio: ratio, first: first.remapped(map), second: second.remapped(map))
        }
    }

    func nearestSplit(on axis: TerminalLayout.Axis, around session: UUID, path: [Int]) -> [Int]? {
        guard case .split(let own, _, let first, let second) = self, contains(session) else { return nil }
        let inner = first.contains(session)
            ? first.nearestSplit(on: axis, around: session, path: path + [0])
            : second.nearestSplit(on: axis, around: session, path: path + [1])
        return inner ?? (own == axis ? path : nil)
    }

    func replacing(_ session: UUID, with node: Self) -> Self {
        switch self {
        case .leaf(let id): id == session ? node : self
        case .split(let axis, let ratio, let first, let second):
            .split(axis, ratio: ratio, first: first.replacing(session, with: node), second: second.replacing(session, with: node))
        }
    }

    func removing(_ session: UUID) -> (node: Self, heir: UUID)? {
        guard case .split(let axis, let ratio, let first, let second) = self else { return nil }
        if first == .leaf(session) { return (second, second.leaves.first ?? session) }
        if second == .leaf(session) { return (first, first.leaves.last ?? session) }
        if first.contains(session), let rest = first.removing(session) {
            return (.split(axis, ratio: ratio, first: rest.node, second: second), rest.heir)
        }
        if second.contains(session), let rest = second.removing(session) {
            return (.split(axis, ratio: ratio, first: first, second: rest.node), rest.heir)
        }
        return nil
    }

    func setting(ratio new: Double, at path: ArraySlice<Int>) -> Self {
        guard case .split(let axis, let ratio, let first, let second) = self else { return self }
        guard let step = path.first else { return .split(axis, ratio: new, first: first, second: second) }
        let rest = path.dropFirst()
        return step == 0
            ? .split(axis, ratio: ratio, first: first.setting(ratio: new, at: rest), second: second)
            : .split(axis, ratio: ratio, first: first, second: second.setting(ratio: new, at: rest))
    }
}

public enum TerminalShortcutKey {
    public static let leftBracketCode: UInt16 = 33
    public static let rightBracketCode: UInt16 = 30

    public static func bracket(characters: String?, keyCode: UInt16) -> Int? {
        switch characters {
        case "[", "{": return -1
        case "]", "}": return 1
        case nil, "":
            if keyCode == leftBracketCode { return -1 }
            if keyCode == rightBracketCode { return 1 }
            return nil
        default: return nil
        }
    }
}

public enum TerminalTabTitle {
    public static func make(custom: String?, command: String?, fallback: String) -> String {
        if let custom, !custom.isEmpty { return custom }
        if let command, let name = commandName(command) { return name }
        return fallback
    }

    public static func commandName(_ command: String) -> String? {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        let skipped: Set<String> = ["sudo", "env", "exec", "command", "builtin", "nohup", "time", "noglob"]
        guard let word = words.first(where: { !$0.contains("=") && !skipped.contains($0) }) else { return nil }
        let name = (word as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
