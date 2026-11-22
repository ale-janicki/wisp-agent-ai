import Darwin
import Foundation

public enum AtomicFile {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case outsideRoot
        case changedOnDisk
        case io(String)

        public var description: String {
            switch self {
            case .outsideRoot: "O arquivo é um atalho para fora da pasta do brain; o Wisp não grava nele."
            case .changedOnDisk: "O arquivo mudou fora do Wisp antes de gravar."
            case .io(let reason): "Não consegui gravar o arquivo (\(reason))."
            }
        }
    }

    public static func write(_ data: Data, to url: URL, root: URL? = nil, expectingHash: String? = nil) throws {
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        if let root, DrawingAttachments.confined(target, to: root) == nil { throw Failure.outsideRoot }
        let directory = target.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".wisp-\(UUID().uuidString).tmp")
        let fileManager = FileManager.default
        let existing = try? fileManager.attributesOfItem(atPath: target.path)
        var created = false
        defer { if created { try? fileManager.removeItem(at: temporary) } }

        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw Failure.io(String(cString: strerror(errno))) }
        created = true
        var failure: String?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 { failure = String(cString: strerror(errno)); return }
                offset += written
            }
        }
        if failure == nil, let mode = existing?[.posixPermissions] as? NSNumber, fchmod(descriptor, mode_t(mode.uint16Value)) != 0 {
            failure = String(cString: strerror(errno))
        }
        if failure == nil, fsync(descriptor) != 0 { failure = String(cString: strerror(errno)) }
        close(descriptor)
        if let failure { throw Failure.io(failure) }

        if let expectingHash {
            guard let current = try? Data(contentsOf: target), DrawingFileState.hash(of: current) == expectingHash else {
                throw Failure.changedOnDisk
            }
        }
        guard rename(temporary.path, target.path) == 0 else { throw Failure.io(String(cString: strerror(errno))) }
        created = false
        let folder = open(directory.path, O_RDONLY)
        if folder >= 0 {
            fsync(folder)
            close(folder)
        }
    }
}
