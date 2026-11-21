import AVFoundation
import os
import WispCore

final class MicrophoneSource: AudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).meetings.mic")
    private var ring: CaptureRing?
    private let log = Logger(subsystem: AppIdentity.bundleID, category: "meetings")
    private var observer: NSObjectProtocol?

    var deviceName: String? { AudioDevices.defaultInputName() }

    func start(ring: CaptureRing) throws {
        guard Self.microphoneAllowed() else {
            throw MeetingRecorderError.source("sem permissão do microfone. Libere o Wisp em Ajustes do Sistema > Privacidade e Segurança > Microfone.")
        }
        try queue.sync {
            self.ring = ring
            try installTapAndStart()
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.rebuild() }
            }
        }
    }

    /// Called off the main thread (the recorder starts on a detached task), so waiting on the prompt is safe.
    private static func microphoneAllowed() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            return false
        case .notDetermined:
            let answered = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                granted = allowed
                answered.signal()
            }
            answered.wait()
            return granted
        default:
            return true
        }
    }

    func stop() {
        queue.sync {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            ring = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    private func installTapAndStart() throws {
        guard let ring else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingRecorderError.source("não encontrei um microfone disponível.")
        }
        let channels = Int(format.channelCount)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            guard let data = buffer.floatChannelData else { return }
            let time = when.isHostTimeValid ? HostClock.seconds(fromHostTime: when.hostTime) : HostClock.nowSeconds()
            ring.push(planar: data, channels: channels, frames: Int(buffer.frameLength), rate: buffer.format.sampleRate, time: time)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MeetingRecorderError.source("o microfone não iniciou (\(error.localizedDescription)).")
        }
    }

    private func rebuild() {
        guard ring != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try installTapAndStart()
        } catch {
            log.error("microphone rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
