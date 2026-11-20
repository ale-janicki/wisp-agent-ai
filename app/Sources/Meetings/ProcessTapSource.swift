import AudioToolbox
import CoreAudio
import Foundation
import WispCore

final class ProcessTapSource: AudioSource, @unchecked Sendable {
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).meetings.tap", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var started = false
    private var ring: CaptureRing?
    private var outputListener: AudioObjectPropertyListenerBlock?

    private static func defaultOutputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    var deviceName: String? { AudioDevices.defaultOutput()?.name }

    func start(ring: CaptureRing) throws {
        try queue.sync {
            self.ring = ring
            do {
                try open()
            } catch {
                close()
                self.ring = nil
                throw error
            }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.queue.async { self?.rebuild() }
            }
            outputListener = listener
            var address = Self.defaultOutputAddress()
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }

    func stop() {
        queue.sync {
            if let outputListener {
                var address = Self.defaultOutputAddress()
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, outputListener)
            }
            outputListener = nil
            ring = nil
            close()
        }
    }

    private func rebuild() {
        guard ring != nil else { return }
        close()
        try? open()
    }

    private func open() throws {
        guard let ring else { return }
        guard let output = AudioDevices.defaultOutput() else {
            throw MeetingRecorderError.source("não encontrei a saída de áudio do Mac.")
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Wisp"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw failure("criar a captura do áudio do sistema", status) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Wisp captura",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw failure("criar o dispositivo de captura", status) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw failure("ler o formato do áudio do sistema", status) }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            throw MeetingRecorderError.source("o áudio do sistema veio num formato que o Wisp não lê.")
        }

        let rate = format.mSampleRate
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, inputTime in
            let time = HostClock.seconds(fromHostTime: inputTime.pointee.mHostTime)
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if buffers.count == 1, let buffer = buffers.first, let data = buffer.mData {
                let samples = UnsafeBufferPointer(
                    start: data.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                )
                ring.push(interleaved: samples, channels: Int(buffer.mNumberChannels), rate: rate, time: time)
                return
            }
            let planeCount = min(buffers.count, CaptureRing.maxChannels)
            guard planeCount > 0 else { return }
            withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: planeCount) { planes in
                var frames = Int.max
                for index in 0..<planeCount {
                    guard let data = buffers[index].mData else { return }
                    planes[index] = data.assumingMemoryBound(to: Float.self)
                    frames = min(frames, Int(buffers[index].mDataByteSize) / MemoryLayout<Float>.size)
                }
                ring.push(planar: UnsafePointer(planes.baseAddress!), channels: planeCount, frames: frames, rate: rate, time: time)
            }
        }
        guard status == noErr else { throw failure("preparar a leitura do áudio do sistema", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw failure("iniciar a captura do áudio do sistema", status) }
        started = true
    }

    private func close() {
        if started, let procID { AudioDeviceStop(aggregateID, procID) }
        started = false
        if let procID, aggregateID != kAudioObjectUnknown { AudioDeviceDestroyIOProcID(aggregateID, procID) }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func failure(_ action: String, _ status: OSStatus) -> MeetingRecorderError {
        .source("não consegui \(action) (erro \(status)). Confira a permissão de áudio do sistema em Ajustes do Sistema > Privacidade e Segurança.")
    }
}
