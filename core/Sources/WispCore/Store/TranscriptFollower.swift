import Foundation

public final class TranscriptFollower: @unchecked Sendable {
    private let sessionId: String
    private let cwd: String
    private let projectsRoot: URL
    private let onChange: @Sendable (TranscriptParser.Snapshot) -> Void
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).transcript-follower")

    private var parser: TranscriptParser
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var reported = false

    public init(
        sessionId: String,
        cwd: String,
        statusPrefix: String?,
        telegramHTML: Bool,
        projectsRoot: URL = TranscriptReader.defaultProjectsRoot,
        onChange: @escaping @Sendable (TranscriptParser.Snapshot) -> Void
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.projectsRoot = projectsRoot
        self.onChange = onChange
        parser = TranscriptParser(statusPrefix: statusPrefix, telegramHTML: telegramHTML)
    }

    public func start() {
        queue.async { [self] in
            let tick = DispatchSource.makeTimerSource(queue: queue)
            tick.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            tick.setEventHandler { [weak self] in self?.poll() }
            timer = tick
            tick.resume()
            poll()
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            timer?.cancel()
            timer = nil
            closeFile()
        }
    }

    deinit {
        timer?.cancel()
        source?.cancel()
    }

    private func poll() {
        guard !stopped else { return }
        if handle == nil {
            open()
            if handle == nil, !reported {
                reported = true
                onChange(parser.snapshot)
            }
            return
        }
        readAppended()
    }

    private func open() {
        guard let found = TranscriptReader.locate(sessionId: sessionId, cwd: cwd, projectsRoot: projectsRoot),
              let file = try? FileHandle(forReadingFrom: found) else { return }
        handle = file
        offset = 0
        let events = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: file.fileDescriptor, eventMask: [.write, .extend, .delete, .rename], queue: queue
        )
        events.setEventHandler { [weak self, weak events] in
            guard let self, let events else { return }
            if !events.data.isDisjoint(with: [.delete, .rename]) {
                self.closeFile()
            } else {
                self.readAppended()
            }
        }
        events.setCancelHandler { try? file.close() }
        source = events
        events.resume()
        readAppended()
    }

    private func readAppended() {
        guard !stopped, let handle else { return }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd(), !data.isEmpty else {
                if !reported { reported = true; onChange(parser.snapshot) }
                return
            }
            offset += UInt64(data.count)
            parser.consume(data)
            reported = true
            onChange(parser.snapshot)
        } catch {
            closeFile()
        }
    }

    private func closeFile() {
        source?.cancel()
        source = nil
        handle = nil
        if offset > 0 {
            parser = TranscriptParser(statusPrefix: parser.statusPrefix, telegramHTML: parser.telegramHTML)
            offset = 0
        }
    }
}
