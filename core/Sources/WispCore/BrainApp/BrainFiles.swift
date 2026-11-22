import Foundation

public enum BrainFilesError: Error, Equatable, LocalizedError {
    case outside(String)
    case invalidName(String)
    case exists(String)
    case missing(String)
    case stale(String)
    case readOnly(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .outside(let path): "\(path) está fora do brain"
        case .invalidName(let path): "nome inválido: \(path)"
        case .exists(let path): "já existe \(path)"
        case .missing(let path): "não achei \(path)"
        case .stale(let path): "\(path) mudou no disco; veja a prévia de novo"
        case .readOnly(let reason): reason
        case .failed(let message): message
        }
    }
}

public struct BrainFiles: Sendable {
    public let root: URL
    private let trasher: @Sendable (URL) throws -> Void

    public init(root: String, trasher: (@Sendable (URL) throws -> Void)? = nil) {
        self.root = URL(fileURLWithPath: BrainScanner.canonical(MemorySearch.resolvedRoot(root)), isDirectory: true)
        self.trasher = trasher ?? { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    public func url(_ rel: String) throws -> URL {
        guard !rel.isEmpty, !rel.hasPrefix("/") else { throw BrainFilesError.outside(rel) }
        for part in rel.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part.hasPrefix(".") { throw BrainFilesError.outside(rel) }
        }
        let url = root.appendingPathComponent(rel)
        var probe = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: probe.path), probe.path.count > root.path.count { probe = probe.deletingLastPathComponent() }
        guard Self.inside(BrainScanner.canonical(probe.path), root.path) else { throw BrainFilesError.outside(rel) }
        return url
    }

    public func validateNew(_ rel: String) throws {
        _ = try url(rel)
        for part in rel.split(separator: "/") where part.contains(":") || part.contains("\\") || part.contains("\0") {
            throw BrainFilesError.invalidName(rel)
        }
    }

    private static func inside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    public func exists(_ rel: String) -> Bool {
        guard let url = try? url(rel) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func read(_ rel: String) throws -> String {
        String(decoding: try data(rel), as: UTF8.self)
    }

    public func data(_ rel: String) throws -> Data {
        do { return try Data(contentsOf: url(rel)) } catch let error as BrainFilesError { throw error } catch { throw BrainFilesError.missing(rel) }
    }

    public static func strictText(_ data: Data) -> String? {
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func readStrict(_ rel: String) throws -> String {
        guard let text = Self.strictText(try data(rel)) else { throw BrainFilesError.readOnly("\(rel) não é texto UTF-8 válido") }
        return text
    }

    public func inspect(_ rel: String) throws -> (text: String, readOnlyReason: String?) {
        let raw = try data(rel)
        if let problem = writeProblem(rel) { return (String(decoding: raw, as: UTF8.self), problem) }
        return (String(decoding: raw, as: UTF8.self), nil)
    }

    public func writeProblem(_ rel: String) -> String? {
        guard let location = try? url(rel) else { return "\(rel) está fora do brain; aberta só para leitura" }
        if FileManager.default.fileExists(atPath: location.path) {
            guard let target = try? resolvedTarget(location) else { return "\(rel) é um link simbólico para fora do brain; aberta só para leitura" }
            guard let raw = try? Data(contentsOf: target), Self.strictText(raw) != nil else {
                return "\(rel) não é texto UTF-8 válido (ou tem bytes nulos); aberta só para leitura e nunca será gravada"
            }
        }
        return nil
    }

    private func resolvedTarget(_ location: URL) throws -> URL {
        let real = BrainScanner.canonical(location.path)
        guard Self.inside(real, root.path) else { throw BrainFilesError.outside(location.lastPathComponent) }
        return URL(fileURLWithPath: real)
    }

    public func write(_ text: String, to rel: String) throws {
        let location = try url(rel)
        var destination = location
        if FileManager.default.fileExists(atPath: location.path) {
            do { destination = try resolvedTarget(location) } catch {
                throw BrainFilesError.readOnly("\(rel) é um link simbólico para fora do brain; não vou gravar nele")
            }
            if let problem = writeProblem(rel) { throw BrainFilesError.readOnly(problem) }
        }
        try Self.replace(Data(text.utf8), at: destination, label: rel)
    }

    static func replace(_ data: Data, at destination: URL, label: String) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString.prefix(8)).wisp-tmp")
        do {
            try data.write(to: temporary)
            copyAttributes(from: destination, to: temporary)
            try rename(temporary, destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw BrainFilesError.failed("não consegui salvar \(label): \(error.localizedDescription)")
        }
    }

    static func copyAttributes(from source: URL, to destination: URL) {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR))
    }

    public func createNote(_ rel: String, text: String = "") throws {
        try validateNew(rel)
        guard !exists(rel) else { throw BrainFilesError.exists(rel) }
        try makeParent(of: rel)
        try write(text, to: rel)
    }

    public func createFolder(_ rel: String) throws {
        try validateNew(rel)
        guard !exists(rel) else { throw BrainFilesError.exists(rel) }
        do { try FileManager.default.createDirectory(at: url(rel), withIntermediateDirectories: true) } catch let error as BrainFilesError {
            throw error
        } catch {
            throw BrainFilesError.failed("não consegui criar \(rel): \(error.localizedDescription)")
        }
    }

    public func trash(_ rel: String) throws {
        guard exists(rel) else { throw BrainFilesError.missing(rel) }
        do { try trasher(url(rel)) } catch let error as BrainFilesError { throw error } catch {
            throw BrainFilesError.failed("não consegui mandar \(rel) para o Lixo: \(error.localizedDescription)")
        }
    }

    public func move(_ from: String, to: String) throws {
        try validateNew(to)
        let source = try url(from), destination = try url(to)
        guard exists(from) else { throw BrainFilesError.missing(from) }
        if exists(to), from.lowercased() != to.lowercased() { throw BrainFilesError.exists(to) }
        try makeParent(of: to)
        do { try Self.rename(source, destination) } catch {
            throw BrainFilesError.failed("não consegui mover \(from): \(error.localizedDescription)")
        }
    }

    func makeParent(of rel: String) throws {
        let parent = BrainText.parent(of: rel)
        guard !parent.isEmpty else { return }
        try FileManager.default.createDirectory(at: url(parent), withIntermediateDirectories: true)
    }

    static func rename(_ from: URL, _ to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
    }
}
