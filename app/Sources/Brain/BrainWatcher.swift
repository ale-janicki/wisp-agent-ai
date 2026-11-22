import CoreServices
import Foundation

final class BrainWatcher: @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        let handler: @Sendable () -> Void
        init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
    }

    private var stream: FSEventStreamRef?
    private var box: Unmanaged<Box>?
    private let queue = DispatchQueue(label: "ai.wisp.brain-watcher", qos: .utility)

    init(root: String, handler: @escaping @Sendable () -> Void) {
        let retained = Unmanaged.passRetained(Box(handler))
        var context = FSEventStreamContext(version: 0, info: retained.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray) as? [String] ?? []
            if list.prefix(count).contains(where: { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }) { box.handler() }
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        guard let created = FSEventStreamCreate(
            nil, callback, &context, [(root as NSString).expandingTildeInPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4, FSEventStreamCreateFlags(flags)
        ) else {
            retained.release()
            return
        }
        box = retained
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
        let box = self.box
        self.box = nil
        queue.async { box?.release() }
    }

    deinit { stop() }
}
