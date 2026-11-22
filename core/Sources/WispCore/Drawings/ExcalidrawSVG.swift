import Foundation

public enum ExcalidrawSVG {
    public static func render(scene: JSONValue, padding: Double = 12, background: Bool = true) -> String? {
        let elements = (scene["elements"]?.arrayValue ?? []).filter { $0["isDeleted"]?.boolValue != true && isDrawable($0) }
        guard !elements.isEmpty else { return nil }

        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for element in elements {
            let box = bounds(of: element)
            minX = min(minX, box.minX); minY = min(minY, box.minY)
            maxX = max(maxX, box.maxX); maxY = max(maxY, box.maxY)
        }
        let width = maxX - minX + padding * 2
        let height = maxY - minY + padding * 2
        let originX = minX - padding
        let originY = minY - padding

        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(num(width))\" height=\"\(num(height))\" viewBox=\"\(num(originX)) \(num(originY)) \(num(width)) \(num(height))\">\n"
        if background {
            let color = scene["appState"]?["viewBackgroundColor"]?.stringValue ?? "#ffffff"
            out += "<rect x=\"\(num(originX))\" y=\"\(num(originY))\" width=\"\(num(width))\" height=\"\(num(height))\" fill=\"\(esc(paint(color)))\"/>\n"
        }
        for element in elements { out += draw(element) }
        out += "</svg>\n"
        return out
    }

    static let coordinateLimit = 1e7

    private static func isDrawable(_ element: JSONValue) -> Bool {
        var numbers = ["x", "y", "width", "height", "angle", "fontSize", "strokeWidth"].compactMap { element[$0]?.doubleValue }
        for point in element["points"]?.arrayValue ?? [] {
            numbers.append(contentsOf: (point.arrayValue ?? []).compactMap(\.doubleValue))
        }
        return numbers.allSatisfy { $0.isFinite && abs($0) <= coordinateLimit }
    }

    private static func num(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let value = min(max(value, -coordinateLimit * 10), coordinateLimit * 10)
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.2f", value)
    }

    private static func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func paint(_ color: String) -> String {
        color.isEmpty ? "none" : color
    }

    private struct Box {
        var minX: Double, minY: Double, maxX: Double, maxY: Double
    }

    private static func points(of element: JSONValue) -> [(Double, Double)] {
        (element["points"]?.arrayValue ?? []).compactMap { point in
            guard let pair = point.arrayValue, pair.count >= 2, let x = pair[0].doubleValue, let y = pair[1].doubleValue else { return nil }
            return (x, y)
        }
    }

    private static func bounds(of element: JSONValue) -> Box {
        let x = element["x"]?.doubleValue ?? 0
        let y = element["y"]?.doubleValue ?? 0
        let width = element["width"]?.doubleValue ?? 0
        let height = element["height"]?.doubleValue ?? 0
        switch element["type"]?.stringValue {
        case "line", "arrow", "freedraw":
            let pts = points(of: element)
            guard !pts.isEmpty else { return Box(minX: x, minY: y, maxX: x + width, maxY: y + height) }
            let xs = pts.map { x + $0.0 }, ys = pts.map { y + $0.1 }
            return Box(minX: xs.min()!, minY: ys.min()!, maxX: xs.max()!, maxY: ys.max()!)
        default:
            return Box(minX: min(x, x + width), minY: min(y, y + height), maxX: max(x, x + width), maxY: max(y, y + height))
        }
    }

    private static func style(_ element: JSONValue, fill: Bool) -> String {
        let stroke = element["strokeColor"]?.stringValue ?? "#1e1e1e"
        let strokeWidth = element["strokeWidth"]?.doubleValue ?? 1
        let background = element["backgroundColor"]?.stringValue ?? "transparent"
        let opacity = (element["opacity"]?.doubleValue ?? 100) / 100
        var attributes = "stroke=\"\(esc(paint(stroke)))\" stroke-width=\"\(num(strokeWidth))\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
        let filled = fill && background != "transparent" && !background.isEmpty
        attributes += " fill=\"\(filled ? esc(background) : "none")\""
        switch element["strokeStyle"]?.stringValue {
        case "dashed": attributes += " stroke-dasharray=\"\(num(strokeWidth * 4)) \(num(strokeWidth * 3))\""
        case "dotted": attributes += " stroke-dasharray=\"\(num(strokeWidth)) \(num(strokeWidth * 3))\""
        default: break
        }
        if opacity < 1 { attributes += " opacity=\"\(String(format: "%.2f", opacity))\"" }
        return attributes
    }

    private static func rotation(_ element: JSONValue) -> String {
        guard let angle = element["angle"]?.doubleValue, abs(angle) > 0.0001 else { return "" }
        let x = element["x"]?.doubleValue ?? 0, y = element["y"]?.doubleValue ?? 0
        let cx = x + (element["width"]?.doubleValue ?? 0) / 2, cy = y + (element["height"]?.doubleValue ?? 0) / 2
        return " transform=\"rotate(\(String(format: "%.3f", angle * 180 / .pi)) \(num(cx)) \(num(cy)))\""
    }

    private static func draw(_ element: JSONValue) -> String {
        let x = element["x"]?.doubleValue ?? 0
        let y = element["y"]?.doubleValue ?? 0
        let width = element["width"]?.doubleValue ?? 0
        let height = element["height"]?.doubleValue ?? 0
        switch element["type"]?.stringValue {
        case "rectangle", "frame", "magicframe", "embeddable", "iframe":
            let rounded = element["roundness"].map { !$0.isNull } ?? false
            let radius = rounded ? min(32, min(width, height) * 0.25) : 0
            return "<rect x=\"\(num(x))\" y=\"\(num(y))\" width=\"\(num(width))\" height=\"\(num(height))\" rx=\"\(num(radius))\" \(style(element, fill: true))\(rotation(element))/>\n"
        case "diamond":
            let d = "M \(num(x + width / 2)) \(num(y)) L \(num(x + width)) \(num(y + height / 2)) L \(num(x + width / 2)) \(num(y + height)) L \(num(x)) \(num(y + height / 2)) Z"
            return "<path d=\"\(d)\" \(style(element, fill: true))\(rotation(element))/>\n"
        case "ellipse":
            return "<ellipse cx=\"\(num(x + width / 2))\" cy=\"\(num(y + height / 2))\" rx=\"\(num(abs(width) / 2))\" ry=\"\(num(abs(height) / 2))\" \(style(element, fill: true))\(rotation(element))/>\n"
        case "line", "arrow":
            return drawLine(element, x: x, y: y)
        case "freedraw":
            let pts = points(of: element)
            guard let first = pts.first else { return "" }
            let d = "M \(num(x + first.0)) \(num(y + first.1)) " + pts.dropFirst().map { "L \(num(x + $0.0)) \(num(y + $0.1))" }.joined(separator: " ")
            return "<path d=\"\(d)\" \(style(element, fill: false))/>\n"
        case "text":
            return drawText(element, x: x, y: y, width: width)
        case "image":
            return "<rect x=\"\(num(x))\" y=\"\(num(y))\" width=\"\(num(width))\" height=\"\(num(height))\" fill=\"#e9ecef\" stroke=\"#adb5bd\" stroke-dasharray=\"4 3\"\(rotation(element))/>\n"
        default:
            return ""
        }
    }

    private static func drawLine(_ element: JSONValue, x: Double, y: Double) -> String {
        let pts = points(of: element).map { (x + $0.0, y + $0.1) }
        guard let first = pts.first, pts.count > 1 else { return "" }
        let d = "M \(num(first.0)) \(num(first.1)) " + pts.dropFirst().map { "L \(num($0.0)) \(num($0.1))" }.joined(separator: " ")
        var out = "<path d=\"\(d)\" \(style(element, fill: false))/>\n"
        if element["type"]?.stringValue == "arrow" {
            let strokeWidth = element["strokeWidth"]?.doubleValue ?? 1
            if let end = element["endArrowhead"], !end.isNull {
                out += arrowhead(at: pts[pts.count - 1], from: pts[pts.count - 2], element: element, size: 12 + strokeWidth * 2)
            }
            if let start = element["startArrowhead"], !start.isNull {
                out += arrowhead(at: pts[0], from: pts[1], element: element, size: 12 + strokeWidth * 2)
            }
        }
        return out
    }

    private static func arrowhead(at tip: (Double, Double), from tail: (Double, Double), element: JSONValue, size: Double) -> String {
        let angle = atan2(tip.1 - tail.1, tip.0 - tail.0)
        let spread = Double.pi / 7
        let left = (tip.0 - size * cos(angle - spread), tip.1 - size * sin(angle - spread))
        let right = (tip.0 - size * cos(angle + spread), tip.1 - size * sin(angle + spread))
        let d = "M \(num(left.0)) \(num(left.1)) L \(num(tip.0)) \(num(tip.1)) L \(num(right.0)) \(num(right.1))"
        return "<path d=\"\(d)\" \(style(element, fill: false))/>\n"
    }

    private static func fontFamily(_ code: Int) -> String {
        switch code {
        case 3, 8: "Menlo, Courier New, monospace"
        case 2, 4, 6, 7: "Helvetica Neue, Helvetica, Arial, sans-serif"
        default: "Bradley Hand, Segoe Print, Comic Sans MS, cursive"
        }
    }

    private static func drawText(_ element: JSONValue, x: Double, y: Double, width: Double) -> String {
        let text = element["text"]?.stringValue ?? ""
        guard !text.isEmpty else { return "" }
        let size = element["fontSize"]?.doubleValue ?? 20
        let lineHeight = element["lineHeight"]?.doubleValue ?? 1.25
        let color = element["strokeColor"]?.stringValue ?? "#1e1e1e"
        let opacity = (element["opacity"]?.doubleValue ?? 100) / 100
        let (anchor, anchorX): (String, Double) = switch element["textAlign"]?.stringValue {
        case "center": ("middle", x + width / 2)
        case "right": ("end", x + width)
        default: ("start", x)
        }
        var out = "<text font-size=\"\(num(size))\" font-family=\"\(esc(fontFamily(element["fontFamily"]?.intValue ?? 1)))\" fill=\"\(esc(paint(color)))\" text-anchor=\"\(anchor)\" xml:space=\"preserve\"\(opacity < 1 ? " opacity=\"\(String(format: "%.2f", opacity))\"" : "")\(rotation(element))>"
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let baseline = y + Double(index) * size * lineHeight + size * 0.92
            out += "<tspan x=\"\(num(anchorX))\" y=\"\(num(baseline))\">\(esc(line))</tspan>"
        }
        return out + "</text>\n"
    }
}

public actor DrawingEmbedCache {
    public static let shared = DrawingEmbedCache(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent(AppIdentity.bundleID, isDirectory: true).appendingPathComponent("drawing-embeds", isDirectory: true))

    private var memory: [String: String] = [:]
    private let folder: URL?

    public init(folder: URL? = nil) {
        self.folder = folder
    }

    public func svg(for url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        let key = DrawingFileState.hash(of: data)
        if let cached = memory[key] { return cached.isEmpty ? nil : cached }
        if let folder, let stored = try? String(contentsOf: folder.appendingPathComponent("\(key).svg"), encoding: .utf8) {
            memory[key] = stored
            return stored.isEmpty ? nil : stored
        }
        let container = ExcalidrawFile.container(forFileNamed: url.lastPathComponent) ?? .markdown
        let file = try ExcalidrawFile.parse(String(decoding: data, as: UTF8.self), container: container)
        let rendered = ExcalidrawSVG.render(scene: file.scene) ?? ""
        memory[key] = rendered
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data(rendered.utf8).write(to: folder.appendingPathComponent("\(key).svg"), options: .atomic)
        }
        return rendered.isEmpty ? nil : rendered
    }

    public var cachedCount: Int { memory.count }
}
