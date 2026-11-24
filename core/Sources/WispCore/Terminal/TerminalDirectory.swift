import Darwin
import Foundation

/// Directory handling for terminal sessions: the OSC 7 report, the system's answer for a pid, and the one remembered directory.
public enum TerminalDirectory {
    /// `file://host/path` (the form OSC 7 carries) or a bare absolute path; nil for anything else.
    public static func path(fromReport report: String?) -> String? {
        guard let report = report?.trimmingCharacters(in: .whitespacesAndNewlines), !report.isEmpty else { return nil }
        if report.hasPrefix("/") { return report }
        guard report.hasPrefix("file://"), let url = URL(string: report), url.isFileURL else { return nil }
        let path = url.path
        return path.hasPrefix("/") ? path : nil
    }

    /// The current directory of one of our own children, read once. Nil when the pid is gone.
    public static func ofProcess(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// The last terminal directory, kept across launches. A directory that no longer exists falls back to home.
    public struct Memory {
        private let load: () -> String?
        private let save: (String) -> Void
        private let isDirectory: (String) -> Bool

        public init(load: @escaping () -> String?, save: @escaping (String) -> Void, isDirectory: @escaping (String) -> Bool = Memory.directoryExists) {
            self.load = load
            self.save = save
            self.isDirectory = isDirectory
        }

        public func startDirectory(home: String) -> String {
            if let remembered = load(), isDirectory(remembered) { return remembered }
            return home
        }

        public func remember(_ path: String) {
            guard path.hasPrefix("/"), path != load() else { return }
            save(path)
        }

        public static func directoryExists(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
