import Darwin
import Foundation

public enum TerminalDirectory {
    public static func path(fromReport report: String?) -> String? {
        guard let report = report?.trimmingCharacters(in: .whitespacesAndNewlines), !report.isEmpty else { return nil }
        if report.hasPrefix("/") { return report }
        guard report.hasPrefix("file://"), let url = URL(string: report), url.isFileURL else { return nil }
        let path = url.path
        return path.hasPrefix("/") ? path : nil
    }

    public static func abbreviated(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

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
