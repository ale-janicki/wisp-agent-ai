import Foundation

public struct CanvasNode: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case text, file, link, group
    }

    public var raw: JSONValue

    public init(raw: JSONValue) { self.raw = raw }

    public init(id: String, kind: Kind, x: Double, y: Double, width: Double, height: Double, text: String? = nil, file: String? = nil, url: String? = nil, label: String? = nil) {
        var members: [JSONMember] = [
            JSONMember(key: "id", value: .string(id)),
            JSONMember(key: "type", value: .string(kind.rawValue)),
        ]
        switch kind {
        case .text: members.append(JSONMember(key: "text", value: .string(text ?? "")))
        case .file: members.append(JSONMember(key: "file", value: .string(file ?? "")))
        case .link: members.append(JSONMember(key: "url", value: .string(url ?? "")))
        case .group: if let label { members.append(JSONMember(key: "label", value: .string(label))) }
        }
        members.append(contentsOf: [
            JSONMember(key: "x", value: .double(x)),
            JSONMember(key: "y", value: .double(y)),
            JSONMember(key: "width", value: .double(width)),
            JSONMember(key: "height", value: .double(height)),
        ])
        raw = .object(members)
    }

    public var id: String { raw["id"]?.stringValue ?? "" }
    public var kind: Kind? { raw["type"]?.stringValue.flatMap(Kind.init(rawValue:)) }
    public var x: Double { get { raw["x"]?.doubleValue ?? 0 } set { raw["x"] = .double(newValue) } }
    public var y: Double { get { raw["y"]?.doubleValue ?? 0 } set { raw["y"] = .double(newValue) } }
    public var width: Double { get { raw["width"]?.doubleValue ?? 0 } set { raw["width"] = .double(newValue) } }
    public var height: Double { get { raw["height"]?.doubleValue ?? 0 } set { raw["height"] = .double(newValue) } }
    public var color: String? { raw["color"]?.stringValue }
    public var text: String? { get { raw["text"]?.stringValue } set { raw["text"] = newValue.map(JSONValue.string) } }
    public var file: String? { raw["file"]?.stringValue }
    public var subpath: String? { raw["subpath"]?.stringValue }
    public var url: String? { raw["url"]?.stringValue }
    public var label: String? { get { raw["label"]?.stringValue } set { raw["label"] = newValue.map(JSONValue.string) } }

    public var linkTarget: String? {
        guard kind == .file, let file else { return nil }
        return file + (subpath ?? "")
    }

    public func contains(_ other: CanvasNode) -> Bool {
        other.x >= x && other.y >= y && other.x + other.width <= x + width && other.y + other.height <= y + height
    }
}

public struct CanvasEdge: Equatable, Identifiable, Sendable {
    public enum Side: String, Sendable {
        case top, right, bottom, left
    }

    public var raw: JSONValue

    public init(raw: JSONValue) { self.raw = raw }

    public init(id: String, from: String, fromSide: Side, to: String, toSide: Side, label: String? = nil) {
        var members: [JSONMember] = [
            JSONMember(key: "id", value: .string(id)),
            JSONMember(key: "fromNode", value: .string(from)),
            JSONMember(key: "fromSide", value: .string(fromSide.rawValue)),
            JSONMember(key: "toNode", value: .string(to)),
            JSONMember(key: "toSide", value: .string(toSide.rawValue)),
        ]
        if let label { members.append(JSONMember(key: "label", value: .string(label))) }
        raw = .object(members)
    }

    public var id: String { raw["id"]?.stringValue ?? "" }
    public var fromNode: String { raw["fromNode"]?.stringValue ?? "" }
    public var toNode: String { raw["toNode"]?.stringValue ?? "" }
    public var fromSide: Side? { raw["fromSide"]?.stringValue.flatMap(Side.init(rawValue:)) }
    public var toSide: Side? { raw["toSide"]?.stringValue.flatMap(Side.init(rawValue:)) }
    public var fromArrow: Bool { raw["fromEnd"]?.stringValue == "arrow" }
    public var toArrow: Bool { (raw["toEnd"]?.stringValue ?? "arrow") == "arrow" }
    public var label: String? { raw["label"]?.stringValue }
    public var color: String? { raw["color"]?.stringValue }
}

public struct JSONCanvas: Equatable, Sendable {
    public enum CanvasError: Error, Equatable, CustomStringConvertible {
        case notACanvas

        public var description: String { "O arquivo não é um JSON Canvas válido." }
    }

    public var nodes: [CanvasNode]
    public var edges: [CanvasEdge]
    public var extraMembers: [JSONMember]
    public var memberOrder: [String]
    public var trailingNewline: Bool
    public var readOnlyNotice: String?

    public init(nodes: [CanvasNode] = [], edges: [CanvasEdge] = [], extraMembers: [JSONMember] = [], memberOrder: [String] = ["nodes", "edges"], trailingNewline: Bool = false) {
        self.nodes = nodes
        self.edges = edges
        self.extraMembers = extraMembers
        self.memberOrder = memberOrder
        self.trailingNewline = trailingNewline
    }

    public static func parse(_ text: String) throws -> JSONCanvas {
        let parsed: (value: JSONValue, lossy: Bool)
        do { parsed = try JSONValue.parseChecked(text) } catch { throw CanvasError.notACanvas }
        let root = parsed.value
        guard let members = root.objectMembers else { throw CanvasError.notACanvas }
        var canvas = JSONCanvas(memberOrder: members.map(\.key), trailingNewline: text.hasSuffix("\n"))
        if parsed.lossy { canvas.readOnlyNotice = lossyNotice }
        canvas.nodes = (root["nodes"]?.arrayValue ?? []).filter { $0.objectMembers != nil }.map(CanvasNode.init(raw:))
        canvas.edges = (root["edges"]?.arrayValue ?? []).filter { $0.objectMembers != nil }.map(CanvasEdge.init(raw:))
        canvas.extraMembers = members.filter { $0.key != "nodes" && $0.key != "edges" }
        return canvas
    }

    public static let lossyNotice = "Este arquivo tem texto que não é UTF-8 válido; o Wisp abre só para leitura para não alterá-lo."

    public static func parse(data: Data) throws -> JSONCanvas {
        guard let text = String(data: data, encoding: .utf8) else {
            var canvas = try parse(String(decoding: data, as: UTF8.self))
            canvas.readOnlyNotice = lossyNotice
            return canvas
        }
        return try parse(text)
    }

    public static func load(from url: URL) throws -> JSONCanvas {
        try parse(data: Data(contentsOf: url))
    }

    public func serialized() -> String {
        var order = memberOrder
        for key in ["nodes", "edges"] where !order.contains(key) { order.append(key) }
        var parts: [String] = []
        for key in order {
            switch key {
            case "nodes": parts.append("\t\"nodes\":" + Self.array(nodes.map(\.raw)))
            case "edges": parts.append("\t\"edges\":" + Self.array(edges.map(\.raw)))
            default:
                if let member = extraMembers.first(where: { $0.key == key }) {
                    parts.append("\t" + JSONValue.string(key).serialized() + ":" + member.value.serialized())
                }
            }
        }
        return "{\n" + parts.joined(separator: ",\n") + "\n}" + (trailingNewline ? "\n" : "")
    }

    private static func array(_ items: [JSONValue]) -> String {
        if items.isEmpty { return "[]" }
        return "[\n" + items.map { "\t\t" + $0.serialized() }.joined(separator: ",\n") + "\n\t]"
    }

    public func write(to url: URL, root: URL? = nil, expectingHash: String? = nil) throws {
        guard readOnlyNotice == nil else { throw AtomicFile.Failure.io(readOnlyNotice ?? "") }
        try AtomicFile.write(Data(serialized().utf8), to: url, root: root, expectingHash: expectingHash)
    }

    public func node(_ id: String) -> CanvasNode? { nodes.first { $0.id == id } }

    public mutating func moveNode(_ id: String, to origin: (x: Double, y: Double)) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].x = origin.x
        nodes[index].y = origin.y
    }

    public mutating func resizeNode(_ id: String, width: Double, height: Double) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].width = max(40, width)
        nodes[index].height = max(30, height)
    }

    public mutating func removeNode(_ id: String) {
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.fromNode == id || $0.toNode == id }
    }

    public mutating func removeEdge(_ id: String) { edges.removeAll { $0.id == id } }

    public mutating func add(_ node: CanvasNode) { nodes.append(node) }

    public mutating func connect(from: String, to: String) {
        guard let source = node(from), let target = node(to), from != to else { return }
        let sides = Self.bestSides(from: source, to: target)
        edges.append(CanvasEdge(id: Self.newID(), from: from, fromSide: sides.0, to: to, toSide: sides.1))
    }

    public mutating func bringToFront(_ id: String) {
        guard let index = nodes.firstIndex(where: { $0.id == id }), index != nodes.count - 1 else { return }
        nodes.append(nodes.remove(at: index))
    }

    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
    }

    public static func bestSides(from a: CanvasNode, to b: CanvasNode) -> (CanvasEdge.Side, CanvasEdge.Side) {
        let dx = (b.x + b.width / 2) - (a.x + a.width / 2)
        let dy = (b.y + b.height / 2) - (a.y + a.height / 2)
        if abs(dx) >= abs(dy) { return dx >= 0 ? (.right, .left) : (.left, .right) }
        return dy >= 0 ? (.bottom, .top) : (.top, .bottom)
    }

    public static func anchor(of node: CanvasNode, side: CanvasEdge.Side) -> (x: Double, y: Double) {
        switch side {
        case .top: (node.x + node.width / 2, node.y)
        case .bottom: (node.x + node.width / 2, node.y + node.height)
        case .left: (node.x, node.y + node.height / 2)
        case .right: (node.x + node.width, node.y + node.height / 2)
        }
    }

    public var bounds: (x: Double, y: Double, width: Double, height: Double)? {
        guard !nodes.isEmpty else { return nil }
        let minX = nodes.map(\.x).min() ?? 0
        let minY = nodes.map(\.y).min() ?? 0
        let maxX = nodes.map { $0.x + $0.width }.max() ?? 0
        let maxY = nodes.map { $0.y + $0.height }.max() ?? 0
        return (minX, minY, maxX - minX, maxY - minY)
    }

    public static func blank() -> JSONCanvas { JSONCanvas() }
}
