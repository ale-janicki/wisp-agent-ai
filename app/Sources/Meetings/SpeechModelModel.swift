import Foundation
import os
import WispCore

@MainActor
final class SpeechModelModel: ObservableObject {
    enum State: Equatable {
        case checking
        case missing
        case downloading(done: Int64, total: Int64)
        case ready
        case failed(String)
    }

    let spec = SpeechModelSpec.parakeetV3

    @Published private(set) var state: State = .checking

    private let log = Logger(subsystem: AppIdentity.bundleID, category: "meetings")
    private var task: Task<Void, Never>?
    private var live: ParakeetRecognizer?
    private var final: ParakeetRecognizer?

    var directory: URL { SpeechModelLocation.directory(for: spec, wispDir: WispFolder.directory()) }

    var isReady: Bool { state == .ready }

    var sizeText: String { ByteCountFormat.gigabytes(spec.totalBytes) }

    func refresh() {
        guard task == nil, state != .ready else { return }
        let spec = spec
        let target = directory
        Task { [weak self] in
            let installed = await Task.detached { SpeechModelLocation.verify(spec, at: target) }.value
            guard let self, self.task == nil else { return }
            self.state = installed ? .ready : .missing
        }
    }

    func download() {
        guard task == nil, state != .ready else { return }
        let spec = spec
        let wispDir = WispFolder.directory()
        state = .downloading(done: 0, total: spec.totalBytes)
        let gate = ProgressGate()
        task = Task { [weak self] in
            do {
                try await SpeechModelDownloader(fetcher: URLSessionModelFetcher()).download(spec, wispDir: wispDir) { done, total in
                    guard gate.allow(done: done, total: total) else { return }
                    Task { @MainActor in self?.progress(done, total) }
                }
                self?.finish(.ready)
            } catch is CancellationError {
                self?.finish(.missing)
            } catch {
                self?.log.error("model download failed: \(error.localizedDescription, privacy: .public)")
                self?.finish(.failed(error.localizedDescription))
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func liveRecognizer() -> ParakeetRecognizer? {
        guard isReady else { return nil }
        if let live { return live }
        let made = ParakeetRecognizer(directory: directory)
        live = made
        return made
    }

    func finalRecognizer() -> ParakeetRecognizer? {
        guard isReady else { return nil }
        if let final { return final }
        let made = ParakeetRecognizer(directory: directory)
        final = made
        return made
    }

    private func progress(_ done: Int64, _ total: Int64) {
        guard case .downloading = state else { return }
        state = .downloading(done: done, total: total)
    }

    private func finish(_ next: State) {
        task = nil
        live = nil
        final = nil
        state = next
    }
}

private final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private static let interval: TimeInterval = 0.25

    func allow(done: Int64, total: Int64) -> Bool {
        lock.withLock {
            let now = Date()
            guard done >= total || now.timeIntervalSince(last) >= Self.interval else { return false }
            last = now
            return true
        }
    }
}
