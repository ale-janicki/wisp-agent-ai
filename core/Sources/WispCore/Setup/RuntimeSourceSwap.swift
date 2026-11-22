import Foundation

public enum RuntimeSourceSwap {
    /// Copies `bundled` next to `destination`, then renames it into place. The old folder is renamed aside first and
    /// removed best-effort, so a runtime still writing into it (bytecode caches) can never leave `destination` half-built.
    public static func install(
        bundled: URL, destination: URL, fileManager fm: FileManager = .default, log: (String) -> Void = { _ in }
    ) throws {
        let parent = destination.deletingLastPathComponent()
        let token = UUID().uuidString
        let fresh = parent.appendingPathComponent("\(destination.lastPathComponent).new-\(token)", isDirectory: true)
        let old = parent.appendingPathComponent("\(destination.lastPathComponent).old-\(token)", isDirectory: true)
        do {
            try fm.copyItem(at: bundled, to: fresh)
        } catch {
            try? fm.removeItem(at: fresh)
            throw error
        }
        let hadOld = fm.fileExists(atPath: destination.path)
        do {
            if hadOld { try fm.moveItem(at: destination, to: old) }
            try fm.moveItem(at: fresh, to: destination)
        } catch {
            if hadOld, !fm.fileExists(atPath: destination.path) { try? fm.moveItem(at: old, to: destination) }
            try? fm.removeItem(at: fresh)
            throw error
        }
        if hadOld { removeBestEffort(old, fileManager: fm, log: log) }
    }

    public static func sweepLeftovers(
        of destination: URL, fileManager fm: FileManager = .default, log: (String) -> Void = { _ in }
    ) {
        let parent = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        guard let entries = try? fm.contentsOfDirectory(atPath: parent.path) else { return }
        for entry in entries where entry.hasPrefix("\(name).old-") || entry.hasPrefix("\(name).new-") {
            removeBestEffort(parent.appendingPathComponent(entry, isDirectory: true), fileManager: fm, log: log)
        }
    }

    private static func removeBestEffort(_ url: URL, fileManager fm: FileManager, log: (String) -> Void) {
        do {
            try fm.removeItem(at: url)
        } catch {
            log("could not remove \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
