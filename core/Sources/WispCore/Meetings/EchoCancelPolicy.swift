import Foundation

/// When the microphone runs through Apple's voice processing (echo cancellation against the system output).
public enum EchoCancelMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case always
    case never

    public var label: String {
        switch self {
        case .automatic: "Automático"
        case .always: "Sempre"
        case .never: "Nunca"
        }
    }
}

public enum EchoCancelPolicy {
    /// Automatic cancels only when the sound comes out of the Mac's own speakers: with headphones or a headset there is
    /// no acoustic path to the mic, and voice processing would only degrade the recorded voice.
    public static func shouldCancel(mode: EchoCancelMode, outputIsBuiltInSpeakers: Bool) -> Bool {
        switch mode {
        case .always: true
        case .never: false
        case .automatic: outputIsBuiltInSpeakers
        }
    }
}

public extension EchoCancelPolicy {
    /// Output data source of the Mac's internal speaker ('ispk'); the headphone jack reports 'hdpn'.
    static let internalSpeakerSource: UInt32 = 0x6973_706B

    /// Whether the default output is the Mac's own speakers. The data source decides when the device has one; when it
    /// is unreadable the device name or UID must say speaker, so a separate "External Headphones" device is not one.
    static func isBuiltInSpeakers(builtInTransport: Bool, dataSource: UInt32?, name: String, uid: String) -> Bool {
        guard builtInTransport else { return false }
        if let dataSource { return dataSource == internalSpeakerSource }
        return ["speaker", "alto-falante"].contains { name.localizedCaseInsensitiveContains($0) }
            || uid.localizedCaseInsensitiveContains("speaker")
    }
}

/// Remembers that voice processing failed on an output route, so it is not retried (each retry restarts the mic)
/// until the output moves to a different route.
public struct VoiceProcessingRetryGate: Equatable, Sendable {
    private var failedRoute: String?

    public init() {}

    /// While true, voice processing stays off.
    public var isBlocked: Bool { failedRoute != nil }

    public mutating func recordFailure(route: String) { failedRoute = route }

    /// Called when the output route changes; a different route allows one more try.
    public mutating func routeChanged(to route: String) {
        if let failedRoute, failedRoute != route { self.failedRoute = nil }
    }
}
