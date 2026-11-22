import Foundation

public struct ExcalidrawFile: Equatable, Sendable {
    public enum Container: Equatable, Sendable {
        case markdown
        case plainJSON
    }

    public enum Encoding: Equatable, Sendable {
        case compressed
        case json
    }

    public struct DataEntry: Equatable, Sendable {
        public var id: String
        public var text: String

        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    public struct TextElement: Equatable, Sendable {
        public let id: String
        public let raw: String
    }

    public struct NewAttachment: Equatable, Sendable {
        public let id: String
        public let mimeType: String
        public let data: Data
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case noDrawingSection
        case corruptedCompression
        case tooLarge
        case invalidScene(String)

        public var description: String {
            switch self {
            case .noDrawingSection: "O arquivo não tem a seção \"## Drawing\" do Excalidraw."
            case .corruptedCompression: "Os dados comprimidos do desenho estão corrompidos."
            case .tooLarge: "Os dados comprimidos do desenho expandem além do limite seguro (50 MB)."
            case .invalidScene(let reason): "A cena do desenho não é um JSON válido (\(reason))."
            }
        }
    }

    public static let pluginHeader = [
        "---", "", "excalidraw-plugin: parsed", "tags: [excalidraw]", "", "---",
        "==⚠  Switch to EXCALIDRAW VIEW in the MORE OPTIONS menu of this document. ⚠== You can decompress Drawing data with the command palette: 'Decompress current Excalidraw file'. For more info check in plugin settings under 'Saving'",
        "", "",
    ].joined(separator: "\n")

    public static let compressedChunk = 256
    public static let fallbackPluginVersion = "2.25.3"
    static let textElementsHeading = "## Text Elements"
    static let elementLinksHeading = "## Element Links"
    static let embeddedFilesHeading = "## Embedded Files"
    static let dataHeading = "# Excalidraw Data"
    static let drawingHeading = "## Drawing"

    public var container: Container
    public var encoding: Encoding
    public var header: String
    public var commentedOut: Bool
    public var elementLinks: [DataEntry]
    public var embeddedFiles: [DataEntry]
    public var scene: JSONValue
    public var trailer: String
    public var indent: String
    public var trailingNewline = true
    public private(set) var notices: [String] = []
    var rawTexts: [String: String]
    var loadedTexts: [String: String]
    var textOrder: [String]
    var loadedIDs: Set<String> = []
    var idAliases: [String: String] = [:]
    static let pluginIDAlphabet = Array("1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    public static let pluginIDLength = 8

    public init(container: Container, encoding: Encoding, header: String = "", commentedOut: Bool = false, elementLinks: [DataEntry] = [], embeddedFiles: [DataEntry] = [], scene: JSONValue, trailer: String = "", indent: String = "\t") {
        self.container = container
        self.encoding = encoding
        self.header = header
        self.commentedOut = commentedOut
        self.elementLinks = elementLinks
        self.embeddedFiles = embeddedFiles
        self.scene = scene
        self.trailer = trailer
        self.indent = indent
        rawTexts = [:]
        loadedTexts = [:]
        textOrder = []
    }

    public static func container(forFileNamed name: String) -> Container? {
        let lower = name.lowercased()
        if lower.hasSuffix(".excalidraw.md") { return .markdown }
        if lower.hasSuffix(".excalidraw") { return .plainJSON }
        return nil
    }

    public static func blank(pluginVersion: String = fallbackPluginVersion, compressed: Bool = true, plain: Bool = false) -> ExcalidrawFile {
        let source = "https://github.com/zsviczian/obsidian-excalidraw-plugin/releases/tag/\(pluginVersion)"
        let scene = JSONValue.object([
            JSONMember(key: "type", value: .string("excalidraw")),
            JSONMember(key: "version", value: .int(2)),
            JSONMember(key: "source", value: .string(source)),
            JSONMember(key: "elements", value: .array([])),
            JSONMember(key: "appState", value: .object([
                JSONMember(key: "gridSize", value: .null),
                JSONMember(key: "viewBackgroundColor", value: .string("#ffffff")),
            ])),
            JSONMember(key: "files", value: .object([])),
        ])
        if plain { return ExcalidrawFile(container: .plainJSON, encoding: .json, scene: scene) }
        return ExcalidrawFile(container: .markdown, encoding: compressed ? .compressed : .json, header: pluginHeader, scene: scene)
    }

    public static func load(from url: URL) throws -> ExcalidrawFile {
        let data = try Data(contentsOf: url)
        return try parse(String(decoding: data, as: UTF8.self), container: container(forFileNamed: url.lastPathComponent) ?? .markdown)
    }

    public static func parse(_ text: String, container: Container) throws -> ExcalidrawFile {
        switch container {
        case .plainJSON:
            var plain = ExcalidrawFile(container: .plainJSON, encoding: .json, scene: try parseScene(text), indent: detectIndent(text))
            plain.trailingNewline = text.hasSuffix("\n")
            return plain
        case .markdown:
            return try parseMarkdown(text)
        }
    }

    private static func parseScene(_ text: String) throws -> JSONValue {
        do {
            let scene = try JSONValue.parse(text)
            guard scene.objectMembers != nil else { throw ParseError.invalidScene("a raiz não é um objeto") }
            return scene
        } catch let error as JSONParseError {
            throw ParseError.invalidScene(error.description)
        }
    }

    private static func parseMarkdown(_ text: String) throws -> ExcalidrawFile {
        let drawingPattern = try NSRegularExpression(pattern: "\\n##? Drawing\\n[^`]*```(compressed-json|json)\\n")
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = drawingPattern.firstMatch(in: text, range: whole),
              let headingRange = Range(match.range, in: text),
              let kindRange = Range(match.range(at: 1), in: text) else { throw ParseError.noDrawingSection }

        let compressed = text[kindRange] == "compressed-json"
        let bodyStart = headingRange.upperBound
        guard let fence = text.range(of: "```\n", range: bodyStart..<text.endIndex) ?? closingFenceAtEnd(text, from: bodyStart) else {
            throw ParseError.noDrawingSection
        }
        let body = String(text[bodyStart..<fence.lowerBound])
        var rest = String(text[fence.upperBound...])
        if rest.hasPrefix("%%") { rest.removeFirst(2) }

        let sceneText: String
        if compressed {
            let stripped = body.filter { $0 != "\n" && $0 != "\r" }
            do {
                sceneText = try LZString.decompressChecked(fromBase64: stripped)
            } catch LZString.DecompressError.tooLarge {
                throw ParseError.tooLarge
            } catch {
                throw ParseError.corruptedCompression
            }
        } else {
            sceneText = body
        }
        let scene = try parseScene(sceneText)

        let preamble = String(text[..<text.index(after: headingRange.lowerBound)])
        let dataRange = preamble.range(of: "(^|\\n)# Excalidraw Data\\n", options: .regularExpression)
        var header = ""
        var region = ""
        var commentedOut = false
        if let dataRange {
            let dataStart = preamble[dataRange].hasPrefix("\n") ? preamble.index(after: dataRange.lowerBound) : dataRange.lowerBound
            header = String(preamble[..<dataStart])
            region = String(preamble[dataRange.upperBound...])
            commentedOut = header.hasSuffix("%%\n")
        } else {
            header = preamble.hasSuffix("\n") ? preamble : preamble + "\n"
        }
        if !commentedOut, region.hasSuffix("%%\n") { region.removeLast(3) }

        let links = entries(inSection: elementLinksHeading, region: region, until: [embeddedFilesHeading])
        let embedded = entries(inSection: embeddedFilesHeading, region: region, until: [])
        var file = ExcalidrawFile(
            container: .markdown,
            encoding: compressed ? .compressed : .json,
            header: header,
            commentedOut: commentedOut,
            elementLinks: links,
            embeddedFiles: embedded,
            scene: scene,
            trailer: rest,
            indent: detectIndent(sceneText)
        )
        file.readTextElements(region: region)
        file.loadedIDs = Set(file.elements.compactMap { $0["id"]?.stringValue })
        return file
    }

    static func detectIndent(_ sceneText: String) -> String {
        let lines = sceneText.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count > 1 else { return "\t" }
        let indent = lines[1].prefix { $0 == " " || $0 == "\t" }
        return indent.isEmpty ? "\t" : String(indent)
    }

    private mutating func readTextElements(region: String) {
        var liveIDs: Set<String> = []
        for element in elements where element["type"]?.stringValue == "text" {
            guard let id = element["id"]?.stringValue else { continue }
            liveIDs.insert(id)
            loadedTexts[id] = element["text"]?.stringValue ?? ""
        }
        guard let headingRange = region.range(of: "\(Self.textElementsHeading)\n") ?? (region.hasPrefix("\(Self.textElementsHeading)") ? region.range(of: Self.textElementsHeading) : nil) else { return }
        var body = String(region[headingRange.upperBound...])
        for stop in ["\n\(Self.elementLinksHeading)\n", "\n\(Self.embeddedFilesHeading)\n"] {
            if let cut = body.range(of: stop) { body = String(body[..<body.index(after: cut.lowerBound)]) }
        }
        for stop in ["\(Self.elementLinksHeading)\n", "\(Self.embeddedFilesHeading)\n"] where body.hasPrefix(stop) { body = "" }
        guard let anchor = try? NSRegularExpression(pattern: "\\s\\^([^\\s^]+)(?=\\n|$)") else { return }
        let ns = body as NSString
        var cursor = 0
        for match in anchor.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: match.range(at: 1))
            guard liveIDs.contains(id), match.range.location >= cursor else { continue }
            rawTexts[id] = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            textOrder.append(id)
            cursor = match.range.location + match.range.length
            while cursor < ns.length, ns.character(at: cursor) == 10 { cursor += 1 }
        }
    }

    private static func closingFenceAtEnd(_ text: String, from start: String.Index) -> Range<String.Index>? {
        guard text.hasSuffix("```") else { return nil }
        let range = text.index(text.endIndex, offsetBy: -3)..<text.endIndex
        return range.lowerBound >= start ? range : nil
    }

    private static func entries(inSection heading: String, region: String, until stops: [String]) -> [DataEntry] {
        let lines = region.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: heading) else { return [] }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            if stops.contains(line) { break }
            if heading == elementLinksHeading, line == embeddedFilesHeading { break }
            body.append(line)
        }
        var entries: [DataEntry] = []
        var current: [String] = []
        var currentID: String?
        var insideLatex = false
        func flush() {
            guard let currentID else { return }
            var text = current
            while text.last == "" { text.removeLast() }
            entries.append(DataEntry(id: currentID, text: text.joined(separator: "\n")))
        }
        for line in body {
            if !insideLatex, let id = entryID(line) {
                flush()
                currentID = id
                current = [line]
            } else if currentID != nil {
                current.append(line)
            }
            if currentID != nil, (line.components(separatedBy: "$$").count - 1) % 2 == 1 {
                insideLatex.toggle()
            }
        }
        flush()
        return entries
    }

    private static func entryID(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
        let id = line[..<colon]
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        return String(id)
    }

    public var elements: [JSONValue] {
        scene["elements"]?.arrayValue ?? []
    }

    public var textElements: [TextElement] { resolvedTexts().elements }

    private func resolvedTexts() -> (elements: [TextElement], notices: [String]) {
        var live: [String: TextElement] = [:]
        var sceneOrder: [String] = []
        var notices: [String] = []
        for element in elements {
            guard element["type"]?.stringValue == "text", element["isDeleted"]?.boolValue != true,
                  let id = element["id"]?.stringValue, live[id] == nil else { continue }
            let text = element["text"]?.stringValue ?? ""
            let original = element["originalText"]?.stringValue ?? text
            let raw: String
            if let loaded = loadedTexts[id], loaded == text {
                if let kept = rawTexts[id] {
                    raw = kept
                } else if let placeholder = element["rawText"]?.stringValue, !placeholder.isEmpty {
                    raw = placeholder
                } else {
                    raw = original
                }
            } else if let old = rawTexts[id], !Self.wikilinkRanges(in: old).isEmpty {
                let result = Self.reinsertLinks(raw: old, edited: original)
                raw = result.text
                notices.append(contentsOf: result.lost.map { "O link \($0) virou texto simples porque o texto dele mudou." })
            } else {
                raw = original
            }
            live[id] = TextElement(id: id, raw: raw)
            sceneOrder.append(id)
        }
        let ordered = textOrder.filter { live[$0] != nil } + sceneOrder.filter { !textOrder.contains($0) }
        return (ordered.compactMap { live[$0] }, notices)
    }

    static func wikilinkRanges(in text: String) -> [(range: Range<String.Index>, inner: String)] {
        guard let regex = try? NSRegularExpression(pattern: "\\[\\[([^\\]\\n]+)\\]\\]") else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { return nil }
            return (whole, String(text[inner]))
        }
    }

    static func reinsertLinks(raw: String, edited: String) -> (text: String, lost: [String]) {
        var result = edited
        var cursor = result.startIndex
        var lost: [String] = []
        for link in wikilinkRanges(in: raw) {
            let parts = link.inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let target = parts[0]
            var candidates: [String] = []
            if parts.count > 1, !parts[1].isEmpty { candidates.append(parts[1]) }
            candidates.append(link.inner)
            candidates.append(target)
            candidates.append(target.replacingOccurrences(of: "#", with: " > "))
            if let last = target.split(separator: "/").last { candidates.append(String(last)) }
            var seen: Set<String> = []
            let ordered = candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
            let markup = String(raw[link.range])
            var replaced = false
            for candidate in ordered {
                if let found = result.range(of: candidate, range: cursor..<result.endIndex) {
                    result.replaceSubrange(found, with: markup)
                    cursor = result.index(found.lowerBound, offsetBy: markup.count)
                    replaced = true
                    break
                }
            }
            if !replaced { lost.append(markup) }
        }
        return (result, lost)
    }

    public func serialized() -> String {
        if container == .plainJSON { return scene.serialized(indent: indent) + (trailingNewline ? "\n" : "") }
        var out = header
        if !header.isEmpty, !header.hasSuffix("\n") { out += "\n" }
        out += "\(Self.dataHeading)\n\n\(Self.textElementsHeading)\n"
        for element in textElements { out += "\(element.raw) ^\(element.id)\n\n" }
        let links = effectiveElementLinks()
        if !links.isEmpty {
            out += "\(Self.elementLinksHeading)\n"
            for link in links { out += "\(link.text)\n\n" }
        }
        if !embeddedFiles.isEmpty {
            out += "\(Self.embeddedFilesHeading)\n"
            for entry in embeddedFiles { out += "\(entry.text)\n\n" }
        }
        if !commentedOut { out += "%%\n" }
        let sceneText = scene.serialized(indent: indent)
        out += "\(Self.drawingHeading)\n"
        switch encoding {
        case .compressed:
            out += "```compressed-json\n\(Self.chunked(LZString.compressToBase64(sceneText)))\n```\n%%"
        case .json:
            out += "```json\n\(sceneText)\n```\n%%"
        }
        out += trailer
        return out
    }

    private func effectiveElementLinks() -> [DataEntry] {
        var result: [DataEntry] = []
        var seen: Set<String> = []
        var live: Set<String> = []
        for element in elements where element["isDeleted"]?.boolValue != true {
            guard let id = element["id"]?.stringValue else { continue }
            live.insert(id)
            if let link = element["link"]?.stringValue, !link.isEmpty, seen.insert(id).inserted {
                result.append(DataEntry(id: id, text: "\(id): \(link)"))
            }
        }
        for entry in elementLinks where live.contains(entry.id) && seen.insert(entry.id).inserted {
            result.append(entry)
        }
        return result
    }

    static func chunked(_ base64: String) -> String {
        var chunks: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: compressedChunk, limitedBy: base64.endIndex) ?? base64.endIndex
            chunks.append(String(base64[index..<end]))
            index = end
        }
        return chunks.joined(separator: "\n\n")
    }

    public func write(to url: URL) throws {
        try Data(serialized().utf8).write(to: url, options: .atomic)
    }

    public static func wikilinkTarget(of entry: DataEntry) -> String? {
        guard let open = entry.text.range(of: "[["), let close = entry.text.range(of: "]]", range: open.upperBound..<entry.text.endIndex) else { return nil }
        let inner = String(entry.text[open.upperBound..<close.lowerBound])
        let target = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? inner
        return target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    public static func mimeType(forFileNamed name: String) -> String? {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        case "bmp": "image/bmp"
        default: nil
        }
    }

    public func filesPayload(resolve: (String) -> URL?) -> JSONValue {
        var members: [JSONMember] = []
        for entry in embeddedFiles {
            guard let target = Self.wikilinkTarget(of: entry), let mime = Self.mimeType(forFileNamed: target),
                  let url = resolve(target), let data = try? Data(contentsOf: url) else { continue }
            let created = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).flatMap { $0 }
            let millis = Int((created ?? Date()).timeIntervalSince1970 * 1000)
            members.append(JSONMember(key: entry.id, value: .object([
                JSONMember(key: "mimeType", value: .string(mime)),
                JSONMember(key: "id", value: .string(entry.id)),
                JSONMember(key: "dataURL", value: .string("data:\(mime);base64,\(data.base64EncodedString())")),
                JSONMember(key: "created", value: .int(millis)),
            ])))
        }
        return .object(members)
    }

    @discardableResult
    public mutating func apply(sceneJSON: String, store: (NewAttachment) throws -> String) throws -> [NewAttachment] {
        var incoming = try Self.parseScene(sceneJSON)
        var created: [NewAttachment] = []
        let known = Set(embeddedFiles.map(\.id))
        let referenced = Self.referencedFileIDs(in: incoming)

        if container == .markdown {
            for member in incoming["files"]?.objectMembers ?? [] where referenced.contains(member.key) && !known.contains(member.key) {
                guard let dataURL = member.value["dataURL"]?.stringValue,
                      let attachment = Self.attachment(id: member.key, mime: member.value["mimeType"]?.stringValue, dataURL: dataURL) else { continue }
                let target = try store(attachment)
                embeddedFiles.append(DataEntry(id: member.key, text: "\(member.key): [[\(target)]]"))
                created.append(attachment)
            }
            incoming["files"] = .object([])
        }
        if container == .markdown, let elements = incoming["elements"]?.arrayValue {
            let reserved = Set(elements.compactMap { $0["id"]?.stringValue })
            var remapped: [JSONValue] = []
            for element in elements { remapped.append(remappingIDs(element, reserved: reserved)) }
            incoming["elements"] = .array(remapped)
        }
        if var merged = scene["appState"]?.objectMembers {
            for member in incoming["appState"]?.objectMembers ?? [] {
                if let index = merged.firstIndex(where: { $0.key == member.key }) { merged[index].value = member.value } else { merged.append(member) }
            }
            incoming["appState"] = .object(merged)
        }
        scene = incoming
        notices = resolvedTexts().notices
        return created
    }

    static func referencedFileIDs(in scene: JSONValue) -> Set<String> {
        Set(scene["elements"]?.arrayValue?.compactMap { element -> String? in
            guard element["type"]?.stringValue == "image", element["isDeleted"]?.boolValue != true else { return nil }
            return element["fileId"]?.stringValue
        } ?? [])
    }

    public var unreferencedEmbeddedIDs: [String] {
        let referenced = Self.referencedFileIDs(in: scene)
        return embeddedFiles.map(\.id).filter { !referenced.contains($0) }
    }

    @discardableResult
    public mutating func pruneEmbeddedFiles() -> Bool {
        let stale = Set(unreferencedEmbeddedIDs)
        guard !stale.isEmpty else { return false }
        embeddedFiles.removeAll { stale.contains($0.id) }
        return true
    }

    private mutating func pluginID(for id: String, reserved: Set<String>) -> String {
        if id.count == Self.pluginIDLength || loadedIDs.contains(id) { return id }
        if let alias = idAliases[id] { return alias }
        var taken = loadedIDs.union(idAliases.values).union(reserved)
        var candidate: String
        repeat {
            candidate = String((0..<Self.pluginIDLength).map { _ in Self.pluginIDAlphabet.randomElement()! })
        } while taken.contains(candidate)
        idAliases[id] = candidate
        return candidate
    }

    private mutating func remappingIDs(_ element: JSONValue, reserved: Set<String>) -> JSONValue {
        var element = element
        for key in ["id", "containerId", "frameId"] {
            if let value = element[key]?.stringValue { element[key] = .string(pluginID(for: value, reserved: reserved)) }
        }
        if let bound = element["boundElements"]?.arrayValue {
            var mapped: [JSONValue] = []
            for var entry in bound {
                if let value = entry["id"]?.stringValue { entry["id"] = .string(pluginID(for: value, reserved: reserved)) }
                mapped.append(entry)
            }
            element["boundElements"] = .array(mapped)
        }
        for key in ["startBinding", "endBinding"] {
            if var binding = element[key], let value = binding["elementId"]?.stringValue {
                binding["elementId"] = .string(pluginID(for: value, reserved: reserved))
                element[key] = binding
            }
        }
        return element
    }

    static func attachment(id: String, mime: String?, dataURL: String) -> NewAttachment? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        let meta = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma]
        guard meta.hasSuffix(";base64"), let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        let resolved = mime ?? String(meta.dropLast(7))
        return NewAttachment(id: id, mimeType: resolved, data: data)
    }

    public static func fileExtension(forMimeType mime: String) -> String {
        switch mime {
        case "image/jpeg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/svg+xml": "svg"
        case "image/bmp": "bmp"
        default: "png"
        }
    }
}
