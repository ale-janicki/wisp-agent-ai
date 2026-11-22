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

    public enum Presence: Sendable, Equatable {
        case text(String)
        case absent
        case unreadable
    }

    public func presence(_ rel: String) -> Presence {
        guard let location = try? url(rel) else { return .unreadable }
        var info = stat()
        if lstat(location.path, &info) != 0 { return errno == ENOENT || errno == ENOTDIR ? .absent : .unreadable }
        guard let raw = try? Data(contentsOf: location), let text = Self.strictText(raw) else { return .unreadable }
        return .text(text)
    }

    public func writeProblem(_ rel: String) -> String? {
        guard let location = try? url(rel) else { return "\(rel) está fora do brain; aberta só para leitura" }
        if FileManager.default.fileExists(atPath: location.path) {
            guard let target = try? resolvedTarget(location) else { return "\(rel) é um link simbólico para fora do brain; aberta só para leitura" }
            if isHardLinked(rel) { return "\(rel) tem mais de um link físico; aberta só para leitura para não separar as cópias" }
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
        let staging: URL
        do {
            staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        } catch {
            throw BrainFilesError.failed("não consegui preparar o salvamento de \(label): \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("note")
        do {
            try stage(data, at: temporary, attributesFrom: destination)
            try rename(temporary, destination)
        } catch {
            throw BrainFilesError.failed("não consegui salvar \(label): \(error.localizedDescription)")
        }
    }

    static func stage(_ data: Data, at temporary: URL, attributesFrom source: URL) throws {
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        guard fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0 || (try? handle.synchronize()) != nil else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "fsync falhou"])
        }
        try copyAttributes(from: source, to: temporary)
    }

    static func copyAttributes(from source: URL, to destination: URL) throws {
        var info = stat()
        guard stat(source.path, &info) == 0 else { return }
        guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "não consegui copiar permissões e atributos"])
        }
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var born = info.st_birthtimespec
        setattrlist(destination.path, &attributes, &born, MemoryLayout<timespec>.size, 0)
    }

    public func sameFile(_ a: String, _ b: String) -> Bool {
        guard let first = try? url(a), let second = try? url(b) else { return false }
        var one = stat(), two = stat()
        guard stat(first.path, &one) == 0, stat(second.path, &two) == 0 else { return false }
        return one.st_dev == two.st_dev && one.st_ino == two.st_ino
    }

    public func isHardLinked(_ rel: String) -> Bool {
        guard let location = try? url(rel) else { return false }
        var info = stat()
        return stat(location.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink > 1
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
        if exists(to), !sameFile(from, to) { throw BrainFilesError.exists(to) }
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
