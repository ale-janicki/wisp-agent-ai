import Foundation

public enum RoutineDiscovery {
    public static let defaultAgentsDirectory = "~/Library/LaunchAgents"

    public static func discover(agents: String? = nil, prefixes: [String]) -> [RoutineJob] {
        let prefixes = prefixes.filter { !$0.isEmpty }
        guard !prefixes.isEmpty else { return [] }
        let directory = expandTilde(agents ?? defaultAgentsDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var jobs: [RoutineJob] = []
        for file in names where file.hasSuffix(".plist") {
            let path = (directory as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: path),
                  let job = job(fromPlist: data, path: path),
                  prefixes.contains(where: { job.label.hasPrefix($0) })
            else { continue }
            jobs.append(job)
        }
        return jobs.sorted { $0.label < $1.label }
    }

    public static func job(fromPlist data: Data, path: String) -> RoutineJob? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty
        else { return nil }
        return RoutineJob(
            label: label,
            name: label.split(separator: ".").last.map(String.init) ?? label,
            description: schedule(fromPlist: plist),
            plist: path,
            logs: RoutineRegistry.logs(fromPlist: data)
        )
    }

    /// Registry order first (registry wins on name/description/logs), then jobs only found on disk.
    public static func merge(
        registry: [RoutineJob],
        discovered: [RoutineJob],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [RoutineJob] {
        let byLabel = Dictionary(discovered.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [RoutineJob] = registry.map { entry in
            var job = entry
            let found = byLabel[entry.label]
            if !fileExists(job.plist), let found { job.plist = found.plist }
            if job.description == nil { job.description = found?.description }
            if job.logs.isEmpty { job.logs = found?.logs ?? [] }
            job.installed = fileExists(job.plist)
            return job
        }
        let known = Set(registry.map(\.label))
        merged += discovered.filter { !known.contains($0.label) }.sorted { $0.label < $1.label }
        return merged
    }

    public static func schedule(fromPlist plist: [String: Any]) -> String {
        if let keepAlive = plist["KeepAlive"] {
            if let flag = keepAlive as? Bool, flag { return "sempre ligado" }
            if let conditions = keepAlive as? [String: Any], !conditions.isEmpty { return "sempre ligado" }
        }
        if let seconds = (plist["StartInterval"] as? NSNumber)?.intValue, seconds > 0 {
            return "a cada " + duration(seconds)
        }
        if let calendar = plist["StartCalendarInterval"] {
            if let one = calendar as? [String: Any] { return calendarText(one) }
            if let many = calendar as? [[String: Any]], let first = many.first {
                return many.count == 1 ? calendarText(first) : "\(many.count) horários"
            }
        }
        if (plist["RunAtLoad"] as? Bool) == true { return "ao ligar" }
        return "sob demanda"
    }

    private static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds % 3600 == 0 { return "\(seconds / 3600) h" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds / 60) min \(seconds % 60) s"
    }

    private static let weekdays = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]

    private static func calendarText(_ entry: [String: Any]) -> String {
        let hour = (entry["Hour"] as? NSNumber)?.intValue
        let minute = (entry["Minute"] as? NSNumber)?.intValue
        let weekday = (entry["Weekday"] as? NSNumber)?.intValue
        let day = (entry["Day"] as? NSNumber)?.intValue
        let when: String
        switch (hour, minute) {
        case (let h?, let m?): when = String(format: "%02d:%02d", h, m)
        case (let h?, nil): when = String(format: "%02d:00", h)
        case (nil, let m?): return "toda hora no minuto \(m)"
        case (nil, nil): when = "00:00"
        }
        if let weekday { return "toda \(weekdays[((weekday % 7) + 7) % 7]) \(when)" }
        if let day { return "todo dia \(day) \(when)" }
        return "todo dia \(when)"
    }
}
