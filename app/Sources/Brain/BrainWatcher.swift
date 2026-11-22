import CoreServices
import Foundation

final class BrainWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "ai.wisp.brain-watcher", qos: .utility)

    init(root: String, handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        let info = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<BrainWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if list.prefix(count).contains(where: { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }) { watcher.handler() }
        }
        guard let created = FSEventStreamCreate(
            nil, callback, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
