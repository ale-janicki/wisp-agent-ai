import AVFoundation
import CryptoKit
import XCTest
@testable import WispCore

final class LiveEncodedRecordingTests: XCTestCase {
    private var root: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let second = CaptureFormat.sampleRate

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("live-encoded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func frames(_ count: Int, from offset: Int = 0) -> [Float] {
        var out = [Float](repeating: 0, count: count * 2)
        for index in 0..<count {
            let wave = 0.3 * sin(Float(offset + index) * 0.05)
            out[index * 2] = wave
            out[index * 2 + 1] = -wave
        }
        return out
    }

    private func length(_ url: URL) throws -> Int { Int(try AVAudioFile(forReading: url).length) }

    private func newFolder() throws -> URL {
        try RecordingFolder.create(root: root, date: t0, timeZone: TimeZone(identifier: "UTC")!)
    }

    private func record(frameCount: Int, in folder: URL) throws {
        let sink = try LiveEncodedSink(rawURL: RecordingFolder.rawAudioURL(in: folder))
        var written = 0
        while written < frameCount {
            let count = min(2_400, frameCount - written)
            try sink.write(frames(count, from: written))
            written += count
        }
        try sink.finish()
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func testSinkEncodesTheM4AWhileRecordingAndKeepsTheRawFileForRecovery() throws {
        let folder = try newFolder()
        try record(frameCount: second * 3, in: folder)
        XCTAssertEqual(try length(RecordingFolder.rawAudioURL(in: folder)), second * 3)
        XCTAssertEqual(try length(LiveRecordingAudio.url(in: folder)), second * 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingFolder.audioURL(in: folder).path))
    }

    func testStopAdoptsTheAlreadyEncodedFileByteForByteWithoutReEncoding() throws {
        let folder = try newFolder()
        try record(frameCount: second * 3, in: folder)
        let before = try digest(LiveRecordingAudio.url(in: folder))
        let seconds = try LiveEncodedConverter().convert(
            from: RecordingFolder.rawAudioURL(in: folder), to: RecordingFolder.audioURL(in: folder)
        )
        XCTAssertEqual(seconds, 3, accuracy: 0.001)
        XCTAssertEqual(try digest(RecordingFolder.audioURL(in: folder)), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LiveRecordingAudio.url(in: folder).path))
        let mode = try FileManager.default.attributesOfItem(atPath: RecordingFolder.audioURL(in: folder).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testCrashedLiveFileIsReplacedByAFullConversionOfTheRawFile() throws {
        let folder = try newFolder()
        try record(frameCount: second * 3, in: folder)
        try Data(count: 64).write(to: LiveRecordingAudio.url(in: folder))
        let destination = RecordingFolder.audioURL(in: folder)
        _ = try LiveEncodedConverter().convert(from: RecordingFolder.rawAudioURL(in: folder), to: destination)
        XCTAssertTrue(M4AFileConverter.covers(written: try length(destination), total: second * 3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: LiveRecordingAudio.url(in: folder).path))
    }

    func testLiveFileShorterThanTheRawFileIsNeverAdopted() throws {
        let folder = try newFolder()
        try record(frameCount: second, in: folder)
        let raw = try StereoFileSink(url: RecordingFolder.rawAudioURL(in: folder), container: .pcm16)
        try raw.write(frames(second * 4))
        try raw.finish()
        let destination = RecordingFolder.audioURL(in: folder)
        _ = try LiveEncodedConverter().convert(from: RecordingFolder.rawAudioURL(in: folder), to: destination)
        XCTAssertEqual(try length(destination), second * 4)
    }

    func testMissingLiveFileFallsBackToTheWholeConversion() throws {
        let folder = try newFolder()
        try record(frameCount: second * 2, in: folder)
        try FileManager.default.removeItem(at: LiveRecordingAudio.url(in: folder))
        let destination = RecordingFolder.audioURL(in: folder)
        _ = try LiveEncodedConverter().convert(from: RecordingFolder.rawAudioURL(in: folder), to: destination)
        XCTAssertTrue(M4AFileConverter.covers(written: try length(destination), total: second * 2))
    }

    func testRecoveryAfterACrashRebuildsFromTheRawFileAndOnlyThenDeletesIt() throws {
        let folder = try newFolder()
        try record(frameCount: second * 3 + 100, in: folder)
        try Data(count: 64).write(to: LiveRecordingAudio.url(in: folder))
        try RecordingFolder.write(RecordingMeta(startedAt: t0, devices: .init(mic: "mic", system: "sys")), in: folder)
        let recovered = RecordingRecovery.recover(root: root, converter: LiveEncodedConverter())
        XCTAssertEqual(recovered.count, 1)
        XCTAssertNil(recovered.first?.failure)
        XCTAssertEqual(try RecordingFolder.read(in: folder).status, .interrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingFolder.rawAudioURL(in: folder).path))
        XCTAssertTrue(M4AFileConverter.covers(written: try length(RecordingFolder.audioURL(in: folder)), total: second * 3 + 100))
    }
}
