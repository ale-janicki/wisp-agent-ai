import Foundation

public enum MeetingTone: Equatable, Sendable {
    case recording, working, ready, failed
}

public struct MeetingStatusBadge: Equatable, Sendable {
    public var label: String
    public var tone: MeetingTone

    public static func make(status: RecordingStatus, working: Bool, hasNote: Bool) -> MeetingStatusBadge {
        switch status {
        case .recording:
            MeetingStatusBadge(label: "gravando", tone: .recording)
        case .transcribing, .interrupted:
            MeetingStatusBadge(label: "transcrevendo", tone: .working)
        case .transcribed:
            if working { MeetingStatusBadge(label: "gerando nota", tone: .working) }
            else if hasNote { MeetingStatusBadge(label: "pronto", tone: .ready) }
            else { MeetingStatusBadge(label: "transcrito", tone: .ready) }
        case .noted:
            MeetingStatusBadge(label: "pronto", tone: .ready)
        case .failed:
            MeetingStatusBadge(label: "falhou", tone: .failed)
        }
    }
}

public struct MeetingRowModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var dateText: String
    public var durationText: String
    public var badge: MeetingStatusBadge
    public var detail: String?

    public init(entry: MeetingEntry, working: Bool, timeZone: TimeZone = .current) {
        id = entry.id
        title = entry.meta.title ?? Self.defaultTitle(entry.meta.startedAt, timeZone: timeZone)
        dateText = Self.dateText(entry.meta.startedAt, timeZone: timeZone)
        durationText = entry.meta.durationSeconds.map { $0 > 0 ? ElapsedFormat.clock($0) : "—" } ?? "—"
        badge = MeetingStatusBadge.make(status: entry.meta.status, working: working, hasNote: entry.hasNote)
        detail = entry.meta.failure
    }

    public static func dateText(_ date: Date, timeZone: TimeZone = .current) -> String {
        format(date, "dd/MM HH:mm", timeZone)
    }

    public static func defaultTitle(_ date: Date, timeZone: TimeZone = .current) -> String {
        "Reunião de \(format(date, "dd/MM 'às' HH:mm", timeZone))"
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

public struct TranscriptLine: Identifiable, Equatable, Sendable {
    public var id: String
    public var time: String
    public var speaker: String
    public var text: String
    public var isPartial: Bool
    public var isMine: Bool
    public var isBookmark = false

    public init(bookmark: MeetingBookmark) {
        id = "bookmark-\(bookmark.id)"
        time = ElapsedFormat.clock(bookmark.time)
        speaker = "Marcador"
        text = bookmark.label.isEmpty ? "Momento marcado" : bookmark.label
        isPartial = false
        isMine = false
        isBookmark = true
    }

    public init(_ segment: MeetingSegment) {
        id = segment.id
        time = ElapsedFormat.clock(segment.start)
        speaker = segment.speakerName
        text = segment.text
        isPartial = !segment.isFinal
        isMine = segment.channel == .mic
    }

    public static func lines(_ segments: [MeetingSegment]) -> [TranscriptLine] {
        segments.map(TranscriptLine.init)
    }
}

public struct ScrollFollower: Equatable, Sendable {
    public static let pinThreshold = 24.0

    public private(set) var isPinned = true

    public init() {}

    public mutating func scrolled(distanceFromBottom: Double) {
        isPinned = distanceFromBottom <= Self.pinThreshold
    }

    public mutating func jumpToEnd() { isPinned = true }

    public var showsJumpButton: Bool { !isPinned }
}

public struct LevelBar: Equatable, Sendable {
    public var fraction: Double
    public var active: Bool

    public init(level: Float, active: Bool) {
        fraction = active ? Double(min(1, max(0, level))) : 0
        self.active = active
    }
}

public struct RecordControl: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, starting, recording, finishing }

    public var title: String
    public var timer: String
    public var isEnabled: Bool
    public var isRecording: Bool

    public init(phase: Phase, elapsed: TimeInterval, canRecord: Bool, savingProgress: Double? = nil) {
        switch phase {
        case .idle:
            title = "Gravar"
            isEnabled = canRecord
        case .starting:
            title = "Iniciando…"
            isEnabled = false
        case .recording:
            title = "Parar"
            isEnabled = true
        case .finishing:
            title = savingProgress.map { "Salvando \(Int(min(1, max(0, $0)) * 100))%" } ?? "Salvando…"
            isEnabled = false
        }
        isRecording = phase == .recording
        timer = ElapsedFormat.clock(phase == .recording ? elapsed : 0)
    }
}

public struct SystemAudioWatch: Equatable, Sendable {
    public private(set) var state: PermissionState
    public private(set) var silentNow = false

    public init(stored: PermissionState = .unknown) {
        state = stored == .granted ? .granted : .unknown
    }

    public var shouldPersist: Bool { state == .granted }

    public mutating func startRecording() { silentNow = false }

    public mutating func observe(level: Float, silentWarning: Bool) {
        if level > 0.02 {
            state = .granted
            silentNow = false
        } else if silentWarning, state != .granted {
            silentNow = true
        }
    }

}

public enum PermissionState: Equatable, Sendable {
    case granted, notDetermined, denied, unknown
}

public struct PermissionCard: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var message: String
    public var buttonTitle: String
    public var settingsURL: URL
    public var neutral = false
}

public enum MeetingPermissions {
    public static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    public static let audioCaptureSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    public static func cards(mic: PermissionState, system: PermissionState, sources: RecordingSources) -> [PermissionCard] {
        var cards: [PermissionCard] = []
        if sources.usesMic, mic == .denied {
            cards.append(PermissionCard(
                id: "mic", title: "O Wisp não pode usar o microfone",
                message: "Libere o Wisp em Privacidade e Segurança > Microfone para gravar a sua voz.",
                buttonTitle: "Abrir Ajustes do Sistema", settingsURL: microphoneSettings
            ))
        }
        if sources.usesSystem, system == .denied {
            cards.append(PermissionCard(
                id: "system", title: "Não estou ouvindo o áudio do Mac",
                message: "Se for falta de permissão, libere o Wisp em Privacidade e Segurança > Gravação de áudio. Se o Mac só está em silêncio, pode ignorar; some quando o som chegar.",
                buttonTitle: "Abrir Ajustes do Sistema", settingsURL: audioCaptureSettings
            ))
        }
        return cards
    }

    public static func silenceHint(sources: RecordingSources, silent: Bool) -> PermissionCard? {
        guard sources.usesSystem, silent else { return nil }
        return PermissionCard(
            id: "system-silence", title: "Não estou ouvindo o Mac",
            message: "Se for falta de permissão, libere o Wisp em Privacidade e Segurança > Gravação de áudio. Se o Mac só está em silêncio, pode ignorar; some quando o som chegar.",
            buttonTitle: "Abrir Ajustes do Sistema", settingsURL: audioCaptureSettings, neutral: true
        )
    }

    public static func hint(mic: PermissionState, system: PermissionState, sources: RecordingSources) -> String? {
        var pending: [String] = []
        if sources.usesMic, mic == .notDetermined { pending.append("o microfone") }
        if sources.usesSystem, system == .unknown { pending.append("o áudio do Mac") }
        guard !pending.isEmpty else { return nil }
        return "O macOS vai pedir permissão para \(pending.joined(separator: " e ")) na primeira gravação."
    }
}

public struct MeetingBrainButton: Equatable, Sendable {
    public var label: String
    public var opensNote: Bool

    public static func make(brainNote: String?, exists: Bool) -> MeetingBrainButton {
        if let brainNote, !brainNote.isEmpty, exists { return MeetingBrainButton(label: "Abrir no brain", opensNote: true) }
        return MeetingBrainButton(label: "Salvar no brain", opensNote: false)
    }
}
