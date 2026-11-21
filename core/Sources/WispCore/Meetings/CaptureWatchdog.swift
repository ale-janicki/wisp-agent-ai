import Foundation

public enum RecordingWarning: String, CaseIterable, Equatable, Sendable {
    case micStalled, systemStalled, systemSilent, overrun

    public var message: String {
        switch self {
        case .micStalled: "o microfone parou"
        case .systemStalled: "o áudio do Mac parou"
        case .systemSilent: "não estou ouvindo o áudio do Mac: libere em Ajustes do Sistema › Privacidade › Gravação de áudio"
        case .overrun: "o Mac está sobrecarregado e partes do áudio foram perdidas"
        }
    }
}

public struct StallWatchdog: Sendable {
    private let timeout: TimeInterval
    private var lastFrames = 0
    private var lastProgress: TimeInterval?

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    public mutating func observe(totalFrames: Int, now: TimeInterval) -> Bool {
        guard let progressed = lastProgress else {
            lastProgress = now
            lastFrames = totalFrames
            return false
        }
        if totalFrames > lastFrames {
            lastFrames = totalFrames
            lastProgress = now
            return false
        }
        return now - progressed >= timeout
    }
}

public struct SilenceDetector: Sendable {
    private let thresholdFrames: Int
    private var zeroFrames = 0
    private var latched = false
    public private(set) var isSilent = false

    public init(threshold: TimeInterval = 10, sampleRate: Int = CaptureFormat.sampleRate) {
        thresholdFrames = Int(threshold * Double(sampleRate))
    }

    public mutating func feed(_ samples: [Float]) {
        if samples.contains(where: { abs($0) > 1e-6 }) {
            zeroFrames = 0
            isSilent = false
            return
        }
        zeroFrames += samples.count
        if zeroFrames >= thresholdFrames, !latched {
            latched = true
            isSilent = true
        }
    }
}
