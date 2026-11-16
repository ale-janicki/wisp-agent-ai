import AppKit
import Combine
import os
import WispCore

@MainActor
final class TimerService: ObservableObject {
    @Published private(set) var list: TimerList
    @Published private(set) var notice: String?

    var onFinish: ((String) -> Void)?

    static let presets = [5, 15, 25, 50]

    private let store: TimerStore
    private let writeQueue = DispatchQueue(label: "com.owner.wisp.timers.write", qos: .utility)
    private var finishTask: Task<Void, Never>?
    private var persists = true
    private let log = Logger(subsystem: "com.owner.wisp", category: "timers")

    init(store: TimerStore = TimerStore()) {
        self.store = store
        list = store.load()
        notice = store.lastRecoveryNote
    }

    func start() {
        checkFinished()
    }

    func start(seconds: Int) {
        list.start(duration: seconds, at: Date())
        changed()
    }

    func pause(_ id: UUID) {
        list.pause(id, at: Date())
        changed()
    }

    func resume(_ id: UUID) {
        list.resume(id, at: Date())
        changed()
    }

    func cancel(_ id: UUID) {
        list.cancel(id)
        changed()
    }

    private func changed() {
        save()
        schedule()
    }

    private func checkFinished() {
        let finished = list.popFinished(at: Date())
        if let line = TimerList.announcement(for: finished) {
            save()
            NSSound(named: "Glass")?.play()
            onFinish?(line)
        }
        schedule()
    }

    private func schedule() {
        finishTask?.cancel()
        guard let end = list.nextEnd else { return }
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.checkFinished()
        }
    }

    private func save() {
        guard persists else { return }
        let snapshot = list
        let store = store
        writeQueue.async { [weak self] in
            do {
                try store.save(snapshot)
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    self?.log.error("timers save failed: \(message, privacy: .public)")
                    self?.notice = "Não consegui salvar os timers: \(message)"
                }
            }
        }
    }

    #if DEBUG
    func applyForSnapshot(_ list: TimerList) {
        persists = false
        finishTask?.cancel()
        self.list = list
    }
    #endif
}
