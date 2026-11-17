import Foundation
import Synchronization
import SwiftUI
import WispCore

actor GraphSimulator {
    struct Frame: Sendable {
        var positions: [SIMD2<Float>] = []
        var edgePaths: [Path] = []
        var nodePaths: [Int: Path] = [:]
        var nodeKey = NodeKey()
        var tick = 0
        var running = false
    }

    struct NodeKey: Equatable, Sendable {
        var zoom: CGFloat = 0
        var size: Float = 0
    }

    enum Command: Sendable {
        case pin(Int, SIMD2<Float>)
        case unpin(Int)
        case alphaTarget(Float)
        case reheat(Float)
        case controls(GraphControls, reheat: Float)
        case scatter(UInt64)
    }

    private struct Shared {
        var inbox: [Command] = []
        var frame = Frame()
        var looping = false
        var stopped = false
        var halted = false
        var nodeKey = NodeKey()
    }

    static let tickInterval: Duration = .microseconds(16_667)
    static let minimumScreenRadius: CGFloat = 1.6
    static let edgeChunk = 16

    nonisolated private let shared: Mutex<Shared>
    private var layout: GraphLayout
    private let edges: [(Int, Int)]
    private let radii: [Float]
    private let groups: [Int]
    private let onRest: @Sendable ([SIMD2<Float>]) -> Void

    init(layout: GraphLayout, edges: [(Int, Int)], radii: [Float], groups: [Int], nodeKey: NodeKey, onRest: @escaping @Sendable ([SIMD2<Float>]) -> Void) {
        self.layout = layout
        self.edges = edges
        self.radii = radii
        self.groups = groups
        self.onRest = onRest
        shared = Mutex(Shared(frame: Frame(positions: layout.positions, running: true), nodeKey: nodeKey))
    }

    nonisolated var frame: Frame { shared.withLock { $0.frame } }

    nonisolated func send(_ commands: Command...) {
        let start = shared.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.inbox.append(contentsOf: commands)
            state.halted = false
            state.frame.running = true
            guard !state.looping else { return false }
            state.looping = true
            return true
        }
        if start { Task.detached(priority: .userInitiated) { await self.run() } }
    }

    nonisolated func start() { send() }

    nonisolated func setNodeKey(_ key: NodeKey) {
        shared.withLock { $0.nodeKey = key }
    }

    nonisolated func stop() {
        shared.withLock {
            $0.stopped = true
            $0.frame.running = false
        }
    }

    nonisolated func halt() {
        shared.withLock { $0.halted = true }
    }

    private func run() async {
        var deadline = ContinuousClock.now
        var moved = false
        var published = (tick: -1, key: NodeKey())
        var tick = shared.withLock { $0.frame.tick }
        while true {
            let (commands, key, stopped, parked) = shared.withLock { state in
                let commands = state.inbox
                state.inbox = []
                let parked = state.halted && commands.isEmpty
                if parked {
                    state.looping = false
                    state.frame.running = false
                }
                return (commands, state.nodeKey, state.stopped, parked)
            }
            if stopped || parked { return }
            for command in commands { apply(command) }
            let wasMoving = !layout.isSettled
            if wasMoving {
                layout.step()
                moved = true
            }
            if wasMoving || !commands.isEmpty || published.tick < 0 || published.key != key {
                tick += 1
                publish(tick: tick, key: key)
                published = (tick, key)
            }
            if layout.isSettled {
                let rest = shared.withLock { state -> Bool in
                    guard state.inbox.isEmpty, state.nodeKey == key else { return false }
                    state.looping = false
                    state.frame.running = false
                    return true
                }
                if rest {
                    if moved { onRest(layout.positions) }
                    return
                }
                continue
            }
            deadline += Self.tickInterval
            let now = ContinuousClock.now
            if deadline < now - Self.tickInterval { deadline = now }
            try? await Task.sleep(until: deadline, clock: .continuous)
        }
    }

    private func apply(_ command: Command) {
        switch command {
        case .pin(let index, let point): layout.pin(index, at: point)
        case .unpin(let index): layout.unpin(index)
        case .alphaTarget(let value): layout.alphaTarget = value
        case .reheat(let value): layout.reheat(to: value)
        case .controls(let controls, let reheat):
            layout.apply(controls)
            if reheat > 0 { layout.reheat(to: reheat) }
        case .scatter(let seed): layout.scatter(seed: seed)
        }
    }

    private func publish(tick: Int, key: NodeKey) {
        let positions = layout.positions
        let edgePaths = Self.edgePaths(edges: edges, positions: positions)
        let nodePaths = Self.nodePaths(positions: positions, radii: radii, groups: groups, key: key)
        shared.withLock { state in
            state.frame = Frame(positions: positions, edgePaths: edgePaths, nodePaths: nodePaths, nodeKey: key, tick: tick, running: true)
        }
    }

    nonisolated static func edgePaths(edges: [(Int, Int)], positions: [SIMD2<Float>]) -> [Path] {
        var chunks: [Path] = []
        chunks.reserveCapacity(edges.count / edgeChunk + 1)
        var chunk = Path()
        for (k, (a, b)) in edges.enumerated() {
            chunk.move(to: CGPoint(x: CGFloat(positions[a].x), y: CGFloat(positions[a].y)))
            chunk.addLine(to: CGPoint(x: CGFloat(positions[b].x), y: CGFloat(positions[b].y)))
            if k % edgeChunk == edgeChunk - 1 {
                chunks.append(chunk)
                chunk = Path()
            }
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    nonisolated static func nodePaths(positions: [SIMD2<Float>], radii: [Float], groups: [Int], key: NodeKey) -> [Int: Path] {
        guard key.zoom > 0 else { return [:] }
        let floor = minimumScreenRadius / key.zoom
        var paths: [Int: Path] = [:]
        for (i, p) in positions.enumerated() {
            let r = max(CGFloat(radii[i] * key.size), floor)
            paths[groups[i], default: Path()].addEllipse(in: CGRect(x: CGFloat(p.x) - r, y: CGFloat(p.y) - r, width: 2 * r, height: 2 * r))
        }
        return paths
    }

    nonisolated static func zoomBucket(_ zoom: CGFloat) -> CGFloat {
        exp2((log2(max(zoom, 1e-3)) * 8).rounded() / 8)
    }
}
