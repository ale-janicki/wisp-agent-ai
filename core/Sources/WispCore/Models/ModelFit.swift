import Foundation

public enum FitLevel: String, Equatable, Sendable {
    case fits, tight, doesNotFit

    public var label: String {
        switch self {
        case .fits: "cabe"
        case .tight: "apertado"
        case .doesNotFit: "não cabe"
        }
    }
}

public struct ModelFit: Equatable, Sendable {
    public var level: FitLevel
    public var diskShortBy: UInt64?
    public var note: String

    public var canInstall: Bool { level != .doesNotFit && diskShortBy == nil }

    public static let fitsShare = 0.5
    public static let tightShare = 0.75

    public static func assess(_ model: LocalModel, on hardware: HardwareProfile, diskMargin: UInt64, installed: Bool = false) -> ModelFit {
        let need = Double(model.memoryBytes)
        let total = Double(hardware.totalMemory)
        let level: FitLevel
        let note: String
        if total <= 0 || need > total * tightShare {
            level = .doesNotFit
            note = "precisa de ~\(gigabytes(model.memoryBytes)) de memória e este Mac tem \(gigabytes(hardware.totalMemory))"
        } else if need > total * fitsShare {
            level = .tight
            note = "usa ~\(gigabytes(model.memoryBytes)) dos \(gigabytes(hardware.totalMemory)); feche outros apps ao usar"
        } else {
            level = .fits
            note = "usa ~\(gigabytes(model.memoryBytes)) dos \(gigabytes(hardware.totalMemory))"
        }
        let required = model.sizeBytes + diskMargin
        let short = (!installed && hardware.freeDisk < required) ? required - hardware.freeDisk : nil
        return ModelFit(level: level, diskShortBy: short, note: note)
    }

    public static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1e9).replacingOccurrences(of: ".", with: ",")
    }
}
