import Foundation

public struct RecoveredRecording: Equatable, Sendable {
    public var folder: URL
    public var durationSeconds: Double
    public var failure: String?
}

public enum RecordingRecovery {
    public static func recover(root: URL, converter: AudioFileConverter, fileManager: FileManager = .default) -> [RecoveredRecording] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var recovered: [RecoveredRecording] = []
        for name in names.sorted() {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard var meta = try? RecordingFolder.read(in: folder), meta.status == .recording else { continue }
            let raw = RecordingFolder.rawAudioURL(in: folder)
            let size = (try? fileManager.attributesOfItem(atPath: raw.path)[.size] as? Int) ?? 0
            guard size > 0 else {
                meta.status = .failed
                meta.failure = "a gravação foi interrompida antes de gravar áudio"
                try? RecordingFolder.write(meta, in: folder)
                recovered.append(RecoveredRecording(folder: folder, durationSeconds: 0, failure: meta.failure))
                continue
            }
            do {
                let duration = try converter.convert(from: raw, to: RecordingFolder.audioURL(in: folder))
                try? fileManager.removeItem(at: raw)
                meta.status = .interrupted
                meta.durationSeconds = duration
                meta.failure = nil
                try? RecordingFolder.write(meta, in: folder)
                recovered.append(RecoveredRecording(folder: folder, durationSeconds: duration, failure: nil))
            } catch {
                meta.status = .failed
                meta.failure = "não consegui recuperar o áudio (\(error.localizedDescription)); o arquivo bruto ficou em \(RecordingFolder.rawAudioFileName)"
                try? RecordingFolder.write(meta, in: folder)
                recovered.append(RecoveredRecording(folder: folder, durationSeconds: 0, failure: meta.failure))
            }
        }
        return recovered
    }
}
