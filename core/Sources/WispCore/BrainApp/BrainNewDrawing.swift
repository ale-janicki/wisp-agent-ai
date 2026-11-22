import Foundation

public enum BrainNewDrawing {
    public enum Kind: Sendable, Equatable {
        case excalidraw
        case canvas

        var prefix: String {
            switch self {
            case .excalidraw: "Desenho"
            case .canvas: "Canvas"
            }
        }

        var suffix: String {
            switch self {
            case .excalidraw: ".excalidraw.md"
            case .canvas: ".canvas"
            }
        }
    }

    public static func content(_ kind: Kind) -> String {
        switch kind {
        case .excalidraw: ExcalidrawFile.blank().serialized()
        case .canvas: JSONCanvas.blank().serialized()
        }
    }

    public static func path(_ kind: Kind, in folder: String, now: Date = Date(), timeZone: TimeZone = .current, exists: (String) -> Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let stem = "\(kind.prefix) \(formatter.string(from: now))"
        var candidate = BrainText.join(folder, stem + kind.suffix)
        var n = 2
        while exists(candidate) {
            candidate = BrainText.join(folder, "\(stem) \(n)\(kind.suffix)")
            n += 1
        }
        return candidate
    }

    @discardableResult
    public static func create(_ kind: Kind, in folder: String, files: BrainFiles, now: Date = Date(), timeZone: TimeZone = .current, knownPaths: Set<String> = []) throws -> String {
        let known = Set(knownPaths.map { $0.lowercased() })
        let rel = path(kind, in: folder, now: now, timeZone: timeZone) { files.exists($0) || known.contains($0.lowercased()) }
        try files.createNote(rel, text: content(kind))
        return rel
    }
}
