import Foundation
import WispCore

enum GitStatusReader {
    private static let git = "/usr/bin/git"
    private static let timeout: TimeInterval = 1

    static func read(directory: String) async -> GitStatus? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: readSync(directory: directory)) }
        }
    }

    static func readSync(directory: String) -> GitStatus? {
        guard let porcelain = run(["status", "--porcelain=v2", "--branch"], directory: directory) else { return nil }
        let shortstat = run(["diff", "HEAD", "--shortstat"], directory: directory) ?? ""
        return GitStatus.parse(porcelain: porcelain, shortstat: shortstat)
    }

    private static func run(_ arguments: [String], directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", directory] + arguments
        process.environment = ["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C", "HOME": NSHomeDirectory()]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        let reader = DispatchQueue.global(qos: .utility)
        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return nil
        }
        drained.wait()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
