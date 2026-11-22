import Foundation

public enum DrawingExportFormat: String, Equatable, Sendable {
    case svg
    case png

    public var fileExtension: String { rawValue }
}

public enum DrawingBridgeEvent: Equatable, Sendable {
    case ready
    case dirty
    case clean
    case changed(scene: String)
    case save(scene: String)
    case exported(format: DrawingExportFormat, data: Data)
    case openLink(String)
    case failure(String)
    case log(String)

    public static let handlerName = "wisp"

    public static func decode(_ body: Any) -> DrawingBridgeEvent? {
        guard let text = body as? String, let message = try? JSONValue.parse(text), let type = message["type"]?.stringValue else { return nil }
        switch type {
        case "ready":
            return .ready
        case "dirty":
            return .dirty
        case "clean":
            return .clean
        case "changed":
            return message["scene"]?.stringValue.map { .changed(scene: $0) }
        case "save":
            return message["scene"]?.stringValue.map { .save(scene: $0) }
        case "exported":
            guard let format = message["format"]?.stringValue.flatMap(DrawingExportFormat.init(rawValue:)),
                  let payload = message["data"]?.stringValue else { return nil }
            switch format {
            case .svg: return .exported(format: .svg, data: Data(payload.utf8))
            case .png: return Data(base64Encoded: payload).map { .exported(format: .png, data: $0) }
            }
        case "openLink":
            return message["link"]?.stringValue.map { .openLink($0) }
        case "failure":
            return .failure(message["message"]?.stringValue ?? "erro desconhecido")
        case "log":
            return .log(message["message"]?.stringValue ?? "")
        default:
            return nil
        }
    }
}

public enum DrawingBridgeCommand: Equatable, Sendable {
    case load(scene: String, files: JSONValue, viewMode: Bool, dark: Bool, language: String)
    case setViewMode(Bool)
    case setTheme(dark: Bool)
    case requestSave
    case export(DrawingExportFormat)

    public var message: JSONValue {
        switch self {
        case .load(let scene, let files, let viewMode, let dark, let language):
            .object([
                JSONMember(key: "type", value: .string("load")),
                JSONMember(key: "scene", value: .string(scene)),
                JSONMember(key: "files", value: files),
                JSONMember(key: "viewMode", value: .bool(viewMode)),
                JSONMember(key: "dark", value: .bool(dark)),
                JSONMember(key: "language", value: .string(language)),
            ])
        case .setViewMode(let viewMode):
            .object([JSONMember(key: "type", value: .string("setViewMode")), JSONMember(key: "viewMode", value: .bool(viewMode))])
        case .setTheme(let dark):
            .object([JSONMember(key: "type", value: .string("setTheme")), JSONMember(key: "dark", value: .bool(dark))])
        case .requestSave:
            .object([JSONMember(key: "type", value: .string("requestSave"))])
        case .export(let format):
            .object([JSONMember(key: "type", value: .string("export")), JSONMember(key: "format", value: .string(format.rawValue))])
        }
    }

    public var script: String {
        "window.wispBridge.receive(\(message.serialized()))"
    }
}

public enum DrawingContentSecurity {
    public static let scheme = "wisp-excalidraw"
    public static let host = "app"
    public static let policy = [
        "default-src 'none'",
        "script-src 'self' 'wasm-unsafe-eval'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob:",
        "font-src 'self' data:",
        "connect-src 'self' data: blob:",
        "worker-src 'self' blob:",
        "media-src 'none'",
        "object-src 'none'",
        "frame-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
    ].joined(separator: "; ")

    public static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "wasm": "application/wasm"
        default: "application/octet-stream"
        }
    }

    public static func resolve(urlPath: String, inside root: URL) -> URL? {
        var relative = urlPath.removingPercentEncoding ?? urlPath
        while relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = "index.html" }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        let base = root.standardizedFileURL.path
        guard candidate.path.hasPrefix(base + "/") else { return nil }
        return candidate
    }
}
