import AVFoundation
import os
import WispCore

final class MicrophoneSource: AudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).meetings.mic")
    private var ring: CaptureRing?
    private let log = Logger(subsystem: AppIdentity.bundleID, category: "meetings")
    private var observer: NSObjectProtocol?
    private let echoCancel: EchoCancelMode
    private var loggedRoute = false
    private var loggedRate = false
    private var routeWatcher: AudioDevices.OutputRouteWatcher?
    /// Voice processing failed on `routeKey`: it stays off until the output moves to another route.
    private var retryGate = VoiceProcessingRetryGate()
    private var routeKey = ""

    init(echoCancel: EchoCancelMode = .automatic) { self.echoCancel = echoCancel }

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
                self?.queue.async { self?.rebuild(keepingVoiceProcessing: true) }
            }
            // The engine does not report an output switch that keeps the format (speakers to headphones), so it is watched here.
            routeWatcher = AudioDevices.OutputRouteWatcher(queue: queue) { [weak self] in self?.routeChanged() }
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
            routeWatcher?.invalidate()
            routeWatcher = nil
            ring = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    /// Turns Apple's voice processing (echo cancellation against the system output) on or off for the input node.
    /// Must run while the engine is stopped. Returns whether it is on; any failure is logged and the plain capture is used.
    private func configureVoiceProcessing(_ input: AVAudioInputNode, enabled: Bool) -> Bool {
        guard input.isVoiceProcessingEnabled != enabled else { return enabled }
        do {
            try input.setVoiceProcessingEnabled(enabled)
        } catch {
            log.error("voice processing \(enabled ? "on" : "off", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if enabled { retryGate.recordFailure(route: routeKey) }
            return input.isVoiceProcessingEnabled
        }
        if enabled {
            // Keep the call audible: minimal ducking of other apps' output.
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min
            )
            log.info("voice processing on, AGC \(input.isVoiceProcessingAGCEnabled, privacy: .public)")
        }
        return enabled
    }

    private func wantsVoiceProcessing() -> Bool {
        let route = AudioDevices.outputRoute()
        routeKey = route?.key ?? ""
        if !loggedRoute {
            loggedRoute = true
            log.info("echo cancel \(self.echoCancel.rawValue, privacy: .public), output transport \(route?.transport ?? "unknown", privacy: .public), built-in speakers \(route?.isBuiltInSpeakers ?? false, privacy: .public)")
        }
        guard !retryGate.isBlocked else { return false }
        return EchoCancelPolicy.shouldCancel(mode: echoCancel, outputIsBuiltInSpeakers: route?.isBuiltInSpeakers ?? false)
    }

    /// Runs on `queue`. A new route lifts an earlier voice processing failure; the capture restarts only when the decision
    /// flips, so plugging headphones mid-call turns it off.
    private func routeChanged() {
        guard ring != nil else { return }
        retryGate.routeChanged(to: AudioDevices.outputRoute()?.key ?? "")
        guard wantsVoiceProcessing() != engine.inputNode.isVoiceProcessingEnabled else { return }
        log.info("output route changed, rebuilding the microphone for echo cancel \(self.echoCancel.rawValue, privacy: .public)")
        rebuild(keepingVoiceProcessing: false)
    }

    /// `keepingVoiceProcessing` (an engine configuration change) leaves voice processing as it is: toggling it posts
    /// another configuration change, so deciding again there could loop. Starts and route changes decide.
    private func installTapAndStart(keepingVoiceProcessing: Bool = false) throws {
        guard ring != nil else { return }
        let input = engine.inputNode
        let wanted = keepingVoiceProcessing ? input.isVoiceProcessingEnabled : wantsVoiceProcessing()
        var processing = configureVoiceProcessing(input, enabled: wanted)
        do {
            try installTap(on: input, voiceProcessing: processing)
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            guard processing else {
                throw MeetingRecorderError.source("o microfone não iniciou (\(error.localizedDescription)).")
            }
            // The device or the system refused voice processing: capture the way it worked before.
            log.error("microphone start with voice processing failed, retrying without: \(error.localizedDescription, privacy: .public)")
            retryGate.recordFailure(route: routeKey)
            processing = configureVoiceProcessing(input, enabled: false)
            do {
                try installTap(on: input, voiceProcessing: processing)
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw MeetingRecorderError.source("o microfone não iniciou (\(error.localizedDescription)).")
            }
        }
    }

    /// The format is read after voice processing is configured: it usually changes (mono, other rate, extra channels).
    /// With voice processing only the first channel carries the cleaned voice, so only it is pushed.
    private func installTap(on input: AVAudioInputNode, voiceProcessing: Bool) throws {
        guard let ring else { return }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingRecorderError.source("não encontrei um microfone disponível.")
        }
        let channels = voiceProcessing ? 1 : Int(format.channelCount)
        if voiceProcessing, !loggedRate {
            loggedRate = true
            log.info("voice processing format \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            guard let data = buffer.floatChannelData else { return }
            let time = when.isHostTimeValid ? HostClock.seconds(fromHostTime: when.hostTime) : HostClock.nowSeconds()
            ring.push(planar: data, channels: channels, frames: Int(buffer.frameLength), rate: buffer.format.sampleRate, time: time)
        }
    }

    private func rebuild(keepingVoiceProcessing: Bool) {
        guard ring != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try installTapAndStart(keepingVoiceProcessing: keepingVoiceProcessing)
        } catch {
            log.error("microphone rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
