import CryptoKit
import Foundation

public struct SpeechModelFile: Equatable, Sendable {
    public enum Hash: Equatable, Sendable {
        case sha256(String)
        case gitBlobSHA1(String)
    }

    public var path: String
    public var size: Int64
    public var hash: Hash

    public init(path: String, size: Int64, hash: Hash) {
        self.path = path
        self.size = size
        self.hash = hash
    }
}

public struct SpeechModelSpec: Equatable, Sendable {
    public var name: String
    public var repo: String
    public var revision: String
    public var folderName: String
    public var license: String
    public var files: [SpeechModelFile]

    public init(name: String, repo: String, revision: String, folderName: String, license: String, files: [SpeechModelFile]) {
        self.name = name
        self.repo = repo
        self.revision = revision
        self.folderName = folderName
        self.license = license
        self.files = files
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public static let attribution = "Modelo Parakeet TDT 0.6b v3 da NVIDIA (nvidia/parakeet-tdt-0.6b-v3), convertido para Core ML por FluidInference, sob a licença CC-BY-4.0 (creativecommons.org/licenses/by/4.0). Foram feitas mudanças de formato (conversão); nenhuma outra."

    public func validate() throws {
        for file in files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            let bad = file.path.isEmpty || file.path.hasPrefix("/") || file.path.contains("\\")
                || file.path.unicodeScalars.contains { $0.value < 0x20 }
                || parts.contains { $0.isEmpty || $0 == ".." || $0 == "." }
            if bad { throw SpeechModelError.badPath(file.path) }
        }
    }

    public var pageURL: URL { URL(string: "https://huggingface.co/\(repo)")! }

    public func downloadURL(for file: SpeechModelFile) -> URL {
        let encoded = file.path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(encoded)")!
    }

    public static let parakeetV3 = SpeechModelSpec(
        name: "Parakeet TDT 0.6b v3",
        repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
        folderName: "parakeet-tdt-0.6b-v3-coreml",
        license: "CC-BY-4.0",
        files: [
        .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, hash: .sha256("4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350")),
        .init(path: "Decoder.mlmodelc/coremldata.bin", size: 554, hash: .sha256("18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99")),
        .init(path: "Decoder.mlmodelc/metadata.json", size: 3427, hash: .gitBlobSHA1("781350d40ed83511afc3bc31a804e6a543e69d04")),
        .init(path: "Decoder.mlmodelc/model.mil", size: 13110, hash: .gitBlobSHA1("95328ba81ca8dceb16c039e62f1a7d447ede43c2")),
        .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 23604992, hash: .sha256("48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41")),
        .init(path: "Encoder_v2.mlmodelc/analytics/coremldata.bin", size: 243, hash: .sha256("af98d71151609799efbbffc00112fcba4bd91adf0b01135a982c574e91822f9c")),
        .init(path: "Encoder_v2.mlmodelc/coremldata.bin", size: 478, hash: .sha256("70628bd4fd25fb554cc0cebc31356723930c885480132bf3ecd1b5dbe71dd0a2")),
        .init(path: "Encoder_v2.mlmodelc/model.mil", size: 1002653, hash: .gitBlobSHA1("af2fb4d2179bdff0eb165993269a8a40eeae6580")),
        .init(path: "Encoder_v2.mlmodelc/weights/weight.bin", size: 594211328, hash: .sha256("8d2c79e15a4545e08fe3a21fe741e42b8bf24329db81de8fdfacd92388ea5a66")),
        .init(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, hash: .sha256("26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c")),
        .init(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 521, hash: .sha256("f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342")),
        .init(path: "JointDecisionv3.mlmodelc/metadata.json", size: 3453, hash: .gitBlobSHA1("0461ef9e55ba8e8ba0d2cb33b6e1a031b0d481d7")),
        .init(path: "JointDecisionv3.mlmodelc/model.mil", size: 11775, hash: .gitBlobSHA1("0a80fde4b1ec61093a03fc0fc3431172db34a4d2")),
        .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12642764, hash: .sha256("4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e")),
        .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, hash: .sha256("c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d")),
        .init(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, hash: .sha256("dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d")),
        .init(path: "Preprocessor.mlmodelc/metadata.json", size: 2841, hash: .gitBlobSHA1("06162c58cf2f5343a0e60f36f843bcdf3cc58527")),
        .init(path: "Preprocessor.mlmodelc/model.mil", size: 28181, hash: .gitBlobSHA1("f987e2479228436c49189aa47edb376db74dcff5")),
        .init(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491072, hash: .sha256("129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea")),
        .init(path: "parakeet_vocab.json", size: 151122, hash: .gitBlobSHA1("c684822ec3b671ebc449c433a7012398d39b8bb0")),
        ]
    )
}

public enum SpeechModelError: Error, Equatable, LocalizedError {
    case lowDisk(neededBytes: Int64, freeBytes: Int64)
    case badStatus(Int)
    case sizeMismatch(path: String)
    case hashMismatch(path: String)
    case badPath(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .lowDisk(let needed, let free):
            "Falta espaço em disco: o modelo precisa de \(ByteCountFormat.gigabytes(needed)) livres e o Mac tem \(ByteCountFormat.gigabytes(free))."
        case .badStatus(let code): "O download do modelo falhou (HTTP \(code))."
        case .sizeMismatch(let path): "O arquivo \(path) do modelo veio com tamanho errado. Tente baixar de novo."
        case .hashMismatch(let path): "O arquivo \(path) do modelo não bate com a assinatura esperada. Tente baixar de novo."
        case .badPath(let path): "O modelo traz um caminho inválido (\(path)) e não foi instalado."
        case .io(let message): "Não consegui gravar o modelo: \(message)"
        }
    }
}

public enum ByteCountFormat {
    public static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    public static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}

public enum SpeechModelLocation {
    public static let verifiedMarker = ".wisp-verified"
    public static let diskMarginBytes: Int64 = 2_000_000_000

    public static func root(wispDir: URL) -> URL {
        wispDir.appendingPathComponent("modelos", isDirectory: true)
    }

    public static func directory(for spec: SpeechModelSpec, wispDir: URL) -> URL {
        root(wispDir: wispDir).appendingPathComponent(spec.folderName, isDirectory: true)
    }

    struct Marker: Codable {
        var revision: String
        var sha256: [String: String]
    }

    static func readMarker(at directory: URL, fileManager: FileManager = .default) -> Marker? {
        fileManager.contents(atPath: directory.appendingPathComponent(verifiedMarker).path)
            .flatMap { try? JSONDecoder().decode(Marker.self, from: $0) }
    }

    public static func isInstalled(_ spec: SpeechModelSpec, at directory: URL, fileManager: FileManager = .default) -> Bool {
        guard let marker = readMarker(at: directory, fileManager: fileManager), marker.revision == spec.revision else { return false }
        return spec.files.allSatisfy { file in
            let attributes = try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(file.path).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == file.size && marker.sha256[file.path] != nil
        }
    }

    public static func verify(_ spec: SpeechModelSpec, at directory: URL, fileManager: FileManager = .default) -> Bool {
        guard (try? spec.validate()) != nil, isInstalled(spec, at: directory, fileManager: fileManager),
              let marker = readMarker(at: directory, fileManager: fileManager) else { return false }
        _ = marker
        for file in spec.files {
            let url = directory.appendingPathComponent(file.path)
            switch file.hash {
            case .sha256(let expected):
                guard (try? FileDigest.sha256(of: url)) == expected.lowercased() else { return false }
            case .gitBlobSHA1:
                guard (try? FileDigest.matches(file, at: url)) == true else { return false }
            }
        }
        return true
    }

    public static func requiredFreeBytes(_ spec: SpeechModelSpec) -> Int64 {
        spec.totalBytes + diskMarginBytes
    }
}

public protocol ModelFileFetcher: Sendable {
    func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
}

public enum FileDigest {
    public static func matches(_ file: SpeechModelFile, at url: URL) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        switch file.hash {
        case .sha256(let expected):
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4_194_304), !chunk.isEmpty { hasher.update(data: chunk) }
            return hex(hasher.finalize()) == expected.lowercased()
        case .gitBlobSHA1(let expected):
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(file.size)\0".utf8))
            while let chunk = try handle.read(upToCount: 4_194_304), !chunk.isEmpty { hasher.update(data: chunk) }
            return hex(hasher.finalize()) == expected.lowercased()
        }
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4_194_304), !chunk.isEmpty { hasher.update(data: chunk) }
        return hex(hasher.finalize())
    }

    private static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct SpeechModelDownloader: Sendable {
    public var fetcher: ModelFileFetcher
    public var diskSpace: DiskSpace
    public var move: @Sendable (URL, URL) throws -> Void

    public init(
        fetcher: ModelFileFetcher, diskSpace: DiskSpace = VolumeDiskSpace(),
        move: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) {
        self.fetcher = fetcher
        self.diskSpace = diskSpace
        self.move = move
    }

    public func download(
        _ spec: SpeechModelSpec, wispDir: URL, progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        try spec.validate()
        let manager = FileManager.default
        let target = SpeechModelLocation.directory(for: spec, wispDir: wispDir)
        let root = target.deletingLastPathComponent()
        let staging = root.appendingPathComponent(spec.folderName + ".partial", isDirectory: true)
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw SpeechModelError.io(error.localizedDescription)
        }
        let kept = (try? stagedBytes(spec, in: staging)) ?? 0
        if let free = diskSpace.availableBytes(at: root), free + kept < SpeechModelLocation.requiredFreeBytes(spec) {
            throw SpeechModelError.lowDisk(neededBytes: SpeechModelLocation.requiredFreeBytes(spec), freeBytes: free)
        }
        let total = spec.totalBytes
        var done: Int64 = 0
        progress(0, total)
        var digests: [String: String] = [:]
        for file in spec.files {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(file.path)
            if manager.fileExists(atPath: destination.path), (try? FileDigest.matches(file, at: destination)) == true {
                digests[file.path] = try FileDigest.sha256(of: destination)
                done += file.size
                progress(done, total)
                continue
            }
            try? manager.removeItem(at: destination)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = destination.appendingPathExtension("part")
            try? manager.removeItem(at: partial)
            let base = done
            try await fetcher.fetch(spec.downloadURL(for: file), to: partial) { received in
                progress(base + min(received, file.size), total)
            }
            let size = (try? manager.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value
            guard size == file.size else {
                try? manager.removeItem(at: partial)
                throw SpeechModelError.sizeMismatch(path: file.path)
            }
            guard try FileDigest.matches(file, at: partial) else {
                try? manager.removeItem(at: partial)
                throw SpeechModelError.hashMismatch(path: file.path)
            }
            try manager.moveItem(at: partial, to: destination)
            digests[file.path] = try FileDigest.sha256(of: destination)
            done += file.size
            progress(done, total)
        }
        do {
            let marker = SpeechModelLocation.Marker(revision: spec.revision, sha256: digests)
            try JSONEncoder().encode(marker).write(to: staging.appendingPathComponent(SpeechModelLocation.verifiedMarker))
        } catch {
            throw SpeechModelError.io(error.localizedDescription)
        }
        try replace(target, with: staging)
    }

    private func replace(_ target: URL, with staging: URL) throws {
        let manager = FileManager.default
        let backup = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".backup")
        try? manager.removeItem(at: backup)
        let hadOld = manager.fileExists(atPath: target.path)
        do {
            if hadOld { try move(target, backup) }
            do {
                try move(staging, target)
            } catch {
                if hadOld { try? manager.moveItem(at: backup, to: target) }
                throw error
            }
        } catch {
            throw SpeechModelError.io(error.localizedDescription)
        }
        try? manager.removeItem(at: backup)
    }

    private func stagedBytes(_ spec: SpeechModelSpec, in staging: URL) throws -> Int64 {
        var sum: Int64 = 0
        for file in spec.files {
            let attributes = try? FileManager.default.attributesOfItem(atPath: staging.appendingPathComponent(file.path).path)
            sum += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return sum
    }
}

public final class URLSessionModelFetcher: ModelFileFetcher, @unchecked Sendable {
    public init() {}

    public func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let transfer = Transfer(destination: destination, progress: progress)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(url, continuation)
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    private final class Transfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let progress: @Sendable (Int64) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var task: URLSessionDownloadTask?
        private var session: URLSession?
        private var failure: Error?
        private var cancelled = false

        init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func start(_ url: URL, _ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let made = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            session = made
            task = made.downloadTask(with: url)
            task?.resume()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let current = task
            lock.unlock()
            current?.cancel()
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            progress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
                failure = SpeechModelError.badStatus(status)
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = SpeechModelError.io(error.localizedDescription)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            session.finishTasksAndInvalidate()
            lock.lock()
            let waiting = continuation
            continuation = nil
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled {
                waiting?.resume(throwing: CancellationError())
            } else if let error {
                waiting?.resume(throwing: error)
            } else if let failure {
                waiting?.resume(throwing: failure)
            } else {
                waiting?.resume()
            }
        }
    }
}
