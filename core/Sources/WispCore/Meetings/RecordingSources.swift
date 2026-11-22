import Foundation

public enum RecordingSources: String, Codable, CaseIterable, Identifiable, Sendable {
    case both
    case mic
    case system

    public var id: String { rawValue }

    public var usesMic: Bool { self != .system }
    public var usesSystem: Bool { self != .mic }

    public var label: String {
        switch self {
        case .both: "Microfone e áudio do Mac"
        case .mic: "Só microfone"
        case .system: "Só áudio do Mac"
        }
    }

    public var shortLabel: String {
        switch self {
        case .both: "Os dois"
        case .mic: "Microfone"
        case .system: "Áudio do Mac"
        }
    }
}
