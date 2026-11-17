import Foundation
import Observation
import QuartzCore
import SwiftUI
import WispCore

struct GraphScene {
    var nodes: [Int] = []
    var edges: [(Int, Int)] = []
    var adjacency: [[Int]] = []
    var radii: [Float] = []
    var groups: [Int] = []
    var version = 0

    var isEmpty: Bool { nodes.isEmpty }
}

struct GraphFade {
    var scene: GraphScene
    var frame: GraphSimulator.Frame
    var started: Double
}

@MainActor @Observable
final class MemoryGraphModel {
    static let shared = MemoryGraphModel()

    enum Phase: Equatable {
        case idle
        case scanning(Int)
        case ready
        case failed(String)
    }

    static let localDepth = 2
    static let zoomRange: ClosedRange<CGFloat> = 0.04...8
    static let overlayInset: CGFloat = 44
    static let hoverDuration: Double = 0.18
    static let fadeDuration: Double = 0.4
    static let dimmed: Double = 0.15

    private(set) var phase: Phase = .idle
    private(set) var graph: LinkGraph = .empty
    private(set) var scene = GraphScene()
    private(set) var settling = false
    private(set) var placeholders = 0
    private(set) var folders: [String] = []
    private(set) var matches: Set<Int> = []
    private(set) var bestMatch: Int?
    private(set) var selected: String?
    private(set) var localMode = false
    private(set) var isAnimating = false
    private(set) var frameTick = 0
    @ObservationIgnored var wakeDisplay: (() -> Void)?
    @ObservationIgnored var displayOwner: ObjectIdentifier?
    var showGhosts = false {
        didSet { if oldValue != showGhosts, let root { load(root: root, force: true) } }
    }

    @ObservationIgnored var offset: CGSize = .zero
    @ObservationIgnored private(set) var zoom: CGFloat = 1
    @ObservationIgnored private(set) var hoverShown: Int?
    @ObservationIgnored private(set) var dragging: Int?
    @ObservationIgnored private(set) var fade: GraphFade?
    @ObservationIgnored private var dragSim: GraphSimulator?
    @ObservationIgnored private var hoverTarget: Int?
    @ObservationIgnored private var hoverProgress: Double = 0
    @ObservationIgnored private var dimProgress: Double = 0
    @ObservationIgnored private var goal: CameraGoal = .fit
    @ObservationIgnored private var momentum: CGVector = .zero
    @ObservationIgnored private var panVelocity: CGVector = .zero
    @ObservationIgnored private var lastPan: Double = 0
    @ObservationIgnored private var grabOffset: SIMD2<Float> = .zero
    @ObservationIgnored private var lastFrame: Double = 0
    @ObservationIgnored private var kicks = 0
    @ObservationIgnored private var viewSize: CGSize = .zero
    @ObservationIgnored private var localPaths: (tick: Int, key: GraphSimulator.NodeKey, paths: [Int: Path])?
    @ObservationIgnored private var scatterSeed: UInt64 = 1

    @ObservationIgnored private var root: String?
    @ObservationIgnored private var scannedRoot: String?
    @ObservationIgnored private var adjacency: [[Int]] = []
    @ObservationIgnored private var groupOfNode: [Int] = []
    @ObservationIgnored private var fullScene = GraphScene()
    @ObservationIgnored private var fullSim: GraphSimulator?
    @ObservationIgnored private var localSim: GraphSimulator?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastLoad: Date?

    private enum CameraGoal {
        case free
        case fit
        case view(zoom: CGFloat, offset: CGSize)
        case anchored(zoom: CGFloat, view: CGPoint, world: CGPoint)
    }

    #if DEBUG
    @ObservationIgnored private(set) var lastScanSeconds: Double?
    @ObservationIgnored private(set) var lastLayoutSeconds: Double?
    @ObservationIgnored private(set) var lastScanStats: LinkScanStats?
    @ObservationIgnored private(set) var scansApplied = 0
    @ObservationIgnored private var layoutStarted: Double?
    #endif

    nonisolated private static var directory: URL {
        ConversationStore.defaultDirectory.appendingPathComponent("graph", isDirectory: true)
    }

    nonisolated private static var linksURL: URL { directory.appendingPathComponent("links.json") }
    nonisolated private static var positionsURL: URL { directory.appendingPathComponent("positions.json") }

    var controls: GraphControls { AppSettings.shared.settings.graph }

    private var activeSim: GraphSimulator? { localMode ? localSim : fullSim }

    var frame: GraphSimulator.Frame { activeSim?.frame ?? GraphSimulator.Frame() }

    // MARK: Loading

    func load(root: String, force: Bool = false) {
        if !force, self.root == root, let lastLoad, Date().timeIntervalSince(lastLoad) < 30 { return }
        if case .scanning = phase, !force { return }
        self.root = root
        lastLoad = Date()
        generation += 1
        let current = generation
        if graph.nodes.isEmpty { phase = .scanning(0) }
        let ghosts = showGhosts
        let shown = fullSim?.frame.positions ?? []
        let onScreen = GraphPositions(root: "", ids: graph.nodes.prefix(shown.count).map(\.id), positions: Array(shown.prefix(graph.nodes.count)))
        let paletteSlots = Theme.Graph.palette.count
        let controls = controls
        Task { [weak self] in
            let started = ContinuousClock.now
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(LinkScan, PreparedGraph), Error> in
                Result {
                    let cache = LinkScanCache.load(from: Self.linksURL)
                    let scan = try LinkGraphScanner.scan(root: root, cache: cache, includeGhosts: ghosts) { count in
                        Task { @MainActor in MemoryGraphModel.shared.progressed(count, generation: current) }
                    }
                    if scan.stats.read > 0 || scan.stats.notes != cache?.files.count { try? scan.cache.save(to: Self.linksURL) }
                    let positions = GraphPositions.load(from: Self.positionsURL).flatMap { $0.root == scan.cache.root ? $0 : nil }
                    let prepared = PreparedGraph(scan: scan, cached: positions, onScreen: onScreen, paletteSlots: paletteSlots, controls: controls)
                    return (scan, prepared)
                }
            }.value
            guard let self, self.generation == current else { return }
            switch outcome {
            case .success(let (scan, prepared)):
                #if DEBUG
                self.lastScanSeconds = Self.seconds(since: started)
                self.lastScanStats = scan.stats
                self.scansApplied += 1
                #endif
                self.apply(scan, prepared: prepared, generation: current)
            case .failure(let error):
                self.phase = .failed("Não consegui ler as notas: \(error.localizedDescription)")
            }
        }
    }

    private func progressed(_ count: Int, generation current: Int) {
        guard generation == current, case .scanning = phase else { return }
        phase = .scanning(count)
    }

    private func apply(_ scan: LinkScan, prepared: PreparedGraph, generation current: Int) {
        graph = scan.graph
        scannedRoot = scan.cache.root
        placeholders = scan.stats.placeholders
        adjacency = prepared.adjacency
        folders = prepared.folders
        groupOfNode = prepared.groupOfNode
        fullScene = GraphScene(
            nodes: Array(graph.nodes.indices),
            edges: prepared.edges,
            adjacency: prepared.adjacency,
            radii: prepared.radii,
            groups: prepared.groupOfNode,
            version: scene.version + 1
        )
        cancelDrag()
        fullSim?.stop()
        settling = !prepared.layout.isSettled
        #if DEBUG
        layoutStarted = settling ? CACurrentMediaTime() : nil
        #endif
        fullSim = makeSimulator(prepared.layout, scene: fullScene) { [weak self] positions in
            guard let self, self.generation == current else { return }
            self.settling = false
            #if DEBUG
            if let started = self.layoutStarted { self.lastLayoutSeconds = CACurrentMediaTime() - started }
            self.layoutStarted = nil
            #endif
            self.savePositions(positions)
        }
        phase = .ready
        if !localMode {
            scene = fullScene
            refreshMatches()
        } else if let center = selectedIndex {
            buildLocalScene(around: center)
        }
        kick()
    }

    private func makeSimulator(_ layout: GraphLayout, scene: GraphScene, rest: @escaping @MainActor ([SIMD2<Float>]) -> Void) -> GraphSimulator {
        let sim = GraphSimulator(
            layout: layout,
            edges: scene.edges,
            radii: scene.radii,
            groups: scene.groups,
            nodeKey: nodeKey
        ) { positions in
            Task { @MainActor in rest(positions) }
        }
        sim.start()
        return sim
    }

    nonisolated private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    private func savePositions(_ positions: [SIMD2<Float>]) {
        let ids = graph.nodes.map(\.id)
        guard let scannedRoot, ids.count == positions.count else { return }
        let snapshot = GraphPositions(root: scannedRoot, ids: ids, positions: positions)
        Task.detached(priority: .utility) { try? snapshot.save(to: Self.positionsURL) }
    }

    // MARK: Scene

    var selectedSceneIndex: Int? {
        guard localMode, let selected else { return nil }
        return scene.nodes.firstIndex { graph.nodes[$0].id == selected }
    }

    private var selectedIndex: Int? {
        guard let selected else { return nil }
        return graph.nodes.firstIndex { $0.id == selected }
    }

    private func fadeOutCurrent() {
        guard !scene.isEmpty else { return }
        fade = GraphFade(scene: scene, frame: frame, started: CACurrentMediaTime())
    }

    private func buildLocalScene(around center: Int) {
        let members = graph.neighborhood(of: center, depth: Self.localDepth, adjacency: adjacency).sorted()
        let local = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1, $0) })
        let edges = graph.edges.compactMap { edge -> GraphEdge? in
            guard let a = local[edge.a], let b = local[edge.b] else { return nil }
            return GraphEdge(a, b)
        }
        var adjacency = Array(repeating: [Int](), count: members.count)
        for edge in edges {
            adjacency[edge.a].append(edge.b)
            adjacency[edge.b].append(edge.a)
        }
        let full = fullSim?.frame.positions ?? []
        let seeds: [SIMD2<Float>?] = members.map { full.indices.contains($0) ? full[$0] : nil }
        let localScene = GraphScene(
            nodes: members,
            edges: edges.map { ($0.a, $0.b) },
            adjacency: adjacency,
            radii: members.map { fullScene.radii.indices.contains($0) ? fullScene.radii[$0] : GraphLayout.radius(degree: 0) },
            groups: members.map { groupOfNode.indices.contains($0) ? groupOfNode[$0] : folders.count },
            version: scene.version + 1
        )
        var layout = GraphLayout(nodeCount: members.count, edges: edges, initial: seeds, radii: localScene.radii, alpha: 1)
        layout.apply(controls)
        cancelDrag()
        localSim?.stop()
        localSim = makeSimulator(layout, scene: localScene) { _ in }
        scene = localScene
        goal = .fit
        hoverTarget = nil
        hoverShown = nil
        refreshMatches()
        kick()
    }

    func setLocalMode(_ on: Bool, fallback: String?) {
        if on, selected == nil { selected = fallback }
        if !on && !localMode { return }
        let next = on && selectedIndex != nil
        guard next != localMode || next else { return }
        cancelDrag()
        fadeOutCurrent()
        localMode = next
        hoverTarget = nil
        hoverShown = nil
        hoverProgress = 0
        if localMode, let center = selectedIndex {
            buildLocalScene(around: center)
        } else {
            localSim?.stop()
            localSim = nil
            scene = fullScene
            goal = .fit
            refreshMatches()
            kick()
        }
    }

    // MARK: Animation

    func kick() {
        kicks += 1
        if !isAnimating {
            lastFrame = CACurrentMediaTime()
            isAnimating = true
            frameTick &+= 1
        }
        wakeDisplay?()
    }

    func displayFrame() {
        frameTick &+= 1
    }

    func advance(to now: Double) {
        let dt = min(max(now - lastFrame, 0), 0.05)
        lastFrame = now
        let current = frame
        var moving = current.running || dragging != nil

        if hoverTarget != hoverShown {
            if let target = hoverTarget {
                if hoverShown == nil { hoverProgress = 0 }
                hoverShown = target
            } else if hoverProgress <= 0 {
                hoverShown = nil
            }
        }
        let hoverGoal: Double = hoverTarget != nil ? 1 : 0
        hoverProgress = step(hoverProgress, toward: hoverGoal, by: dt / Self.hoverDuration)
        if hoverProgress <= 0, hoverTarget == nil { hoverShown = nil }
        let dimGoal: Double = hoverTarget != nil || !matches.isEmpty ? 1 : 0
        dimProgress = step(dimProgress, toward: dimGoal, by: dt / Self.hoverDuration)
        if hoverProgress != hoverGoal || dimProgress != dimGoal { moving = true }

        if momentum != .zero {
            offset.width += momentum.dx * dt
            offset.height += momentum.dy * dt
            let keep = exp(-dt / 0.25)
            momentum = CGVector(dx: momentum.dx * keep, dy: momentum.dy * keep)
            if hypot(momentum.dx, momentum.dy) < 6 { momentum = .zero } else { moving = true }
        }

        if moveCamera(dt: dt, positions: current.positions) { moving = true }

        if let fade, now - fade.started >= Self.fadeDuration { self.fade = nil }
        if fade != nil { moving = true }

        let key = nodeKey
        if key != current.nodeKey { activeSim?.setNodeKey(key) }

        if !moving, isAnimating {
            let pending = kicks
            DispatchQueue.main.async { [weak self] in
                guard let self, self.kicks == pending else { return }
                self.isAnimating = false
            }
        }
    }

    private func step(_ value: Double, toward target: Double, by amount: Double) -> Double {
        value < target ? min(value + amount, target) : max(value - amount, target)
    }

    var hoverAmount: Double { hoverProgress * hoverProgress * (3 - 2 * hoverProgress) }
    var dimAmount: Double { dimProgress * dimProgress * (3 - 2 * dimProgress) }

    func fadeProgress(at now: Double) -> Double {
        guard let fade else { return 1 }
        let t = min(max((now - fade.started) / Self.fadeDuration, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func moveCamera(dt: Double, positions: [SIMD2<Float>]) -> Bool {
        let k = CGFloat(1 - exp(-dt / 0.11))
        switch goal {
        case .free:
            return false
        case .fit:
            guard let target = fitted(positions) else { return false }
            return ease(toward: target.zoom, offset: target.offset, k: k)
        case .view(let zoom, let offset):
            let moving = ease(toward: zoom, offset: offset, k: k)
            if !moving { goal = .free }
            return moving
        case .anchored(let target, let view, let world):
            let next = exp(log(zoom) + (log(target) - log(zoom)) * k)
            let done = abs(log(target) - log(next)) < 0.002
            zoom = done ? target : next
            offset = CGSize(width: view.x - viewSize.width / 2 - world.x * zoom, height: view.y - viewSize.height / 2 - world.y * zoom)
            if done { goal = .free }
            return !done
        }
    }

    private func ease(toward target: CGFloat, offset goalOffset: CGSize, k: CGFloat) -> Bool {
        let close = abs(log(target) - log(zoom)) < 0.002 && hypot(goalOffset.width - offset.width, goalOffset.height - offset.height) < 0.3
        if close {
            zoom = target
            offset = goalOffset
            return false
        }
        zoom = exp(log(zoom) + (log(target) - log(zoom)) * k)
        offset.width += (goalOffset.width - offset.width) * k
        offset.height += (goalOffset.height - offset.height) * k
        return true
    }

    private func fitted(_ positions: [SIMD2<Float>]) -> (zoom: CGFloat, offset: CGSize)? {
        guard var minX = positions.first?.x, var minY = positions.first?.y, viewSize.width > 0, viewSize.height > 0 else { return nil }
        var maxX = minX, maxY = minY
        for p in positions {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        let bounds = CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY)).insetBy(dx: -12, dy: -12)
        let usable = CGSize(width: viewSize.width - 24, height: viewSize.height - 2 * Self.overlayInset)
        let scale = min(usable.width / max(bounds.width, 1), max(usable.height, 40) / max(bounds.height, 1))
        let zoom = min(max(scale, Self.zoomRange.lowerBound), 2.5)
        return (zoom, CGSize(width: -bounds.midX * zoom, height: -bounds.midY * zoom))
    }

    private var nodeKey: GraphSimulator.NodeKey {
        GraphSimulator.NodeKey(zoom: GraphSimulator.zoomBucket(zoom), size: controls.nodeSize)
    }

    func nodePaths(for frame: GraphSimulator.Frame, scene: GraphScene) -> [Int: Path] {
        let key = nodeKey
        if frame.nodeKey == key { return frame.nodePaths }
        if let cached = localPaths, cached.tick == frame.tick, cached.key == key, cached.paths.count > 0 || frame.positions.isEmpty { return cached.paths }
        guard frame.positions.count == scene.radii.count else { return frame.nodePaths }
        let paths = GraphSimulator.nodePaths(positions: frame.positions, radii: scene.radii, groups: scene.groups, key: key)
        localPaths = (frame.tick, key, paths)
        return paths
    }

    // MARK: Interaction

    func setViewSize(_ size: CGSize) {
        guard size != viewSize else { return }
        viewSize = size
        if case .fit = goal, let target = fitted(frame.positions) {
            zoom = target.zoom
            offset = target.offset
        }
        kick()
    }

    func fit() {
        goal = .fit
        momentum = .zero
        kick()
    }

    func pan(by delta: CGSize, at time: Double = CACurrentMediaTime()) {
        goal = .free
        momentum = .zero
        offset.width += delta.width
        offset.height += delta.height
        let dt = time - lastPan
        if dt > 0, dt < 0.1 {
            let blend = 0.35
            panVelocity = CGVector(
                dx: panVelocity.dx * (1 - blend) + delta.width / dt * blend,
                dy: panVelocity.dy * (1 - blend) + delta.height / dt * blend
            )
        } else {
            panVelocity = .zero
        }
        lastPan = time
        kick()
    }

    func endPan(at time: Double = CACurrentMediaTime()) {
        if time - lastPan < 0.06, hypot(panVelocity.dx, panVelocity.dy) > 80 {
            momentum = panVelocity
        }
        panVelocity = .zero
        kick()
    }

    private var viewCenter: CGPoint {
        CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    }

    func stopMomentum() {
        momentum = .zero
    }

    func zoom(by factor: CGFloat, at anchor: CGPoint?) {
        goal = .free
        let point = anchor ?? viewCenter
        let world = toWorld(point)
        zoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        offset = CGSize(width: point.x - viewSize.width / 2 - world.x * zoom, height: point.y - viewSize.height / 2 - world.y * zoom)
        kick()
    }

    func zoomSmoothly(by factor: CGFloat, at anchor: CGPoint?) {
        let point = anchor ?? viewCenter
        let base: CGFloat
        if case .anchored(let target, _, _) = goal { base = target } else { base = zoom }
        let target = min(max(base * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        momentum = .zero
        goal = .anchored(zoom: target, view: point, world: toWorld(point))
        kick()
    }

    func toWorld(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - viewSize.width / 2 - offset.width) / zoom,
            y: (point.y - viewSize.height / 2 - offset.height) / zoom
        )
    }

    func toView(_ world: CGPoint) -> CGPoint {
        CGPoint(x: viewSize.width / 2 + offset.width + world.x * zoom, y: viewSize.height / 2 + offset.height + world.y * zoom)
    }

    func toView(_ world: SIMD2<Float>) -> CGPoint {
        toView(CGPoint(x: CGFloat(world.x), y: CGFloat(world.y)))
    }

    func node(at point: CGPoint) -> Int? {
        let positions = frame.positions
        guard positions.count == scene.nodes.count else { return nil }
        let world = toWorld(point)
        var best: Int?
        var bestDistance = CGFloat.infinity
        for (i, p) in positions.enumerated() {
            let dx = CGFloat(p.x) - world.x, dy = CGFloat(p.y) - world.y
            let distance = dx * dx + dy * dy
            let reach = (max(radius(ofScene: i) * zoom, GraphSimulator.minimumScreenRadius) + 4) / zoom
            if distance < reach * reach, distance < bestDistance {
                best = i
                bestDistance = distance
            }
        }
        return best
    }

    func hover(at point: CGPoint?) {
        guard dragging == nil else { return }
        let next = point.flatMap(node(at:))
        if next != hoverTarget {
            hoverTarget = next
            kick()
        }
    }

    var isHovering: Bool { hoverTarget != nil }

    func beginDrag(_ index: Int, at point: CGPoint) {
        guard displayOwner != nil, let sim = activeSim, frame.positions.indices.contains(index) else { return }
        let world = toWorld(point)
        grabOffset = frame.positions[index] - SIMD2(Float(world.x), Float(world.y))
        dragging = index
        dragSim = sim
        hoverTarget = index
        goal = .free
        momentum = .zero
        sim.send(.pin(index, frame.positions[index]), .alphaTarget(GraphLayout.dragAlpha), .reheat(GraphLayout.dragAlpha))
        kick()
    }

    func drag(to point: CGPoint) {
        guard let index = dragging, let sim = dragSim else { return }
        let world = toWorld(point)
        sim.send(.pin(index, SIMD2(Float(world.x), Float(world.y)) + grabOffset))
        kick()
    }

    func endDrag(at point: CGPoint?) {
        guard let index = dragging else { return }
        dragSim?.send(.unpin(index), .alphaTarget(0))
        dragging = nil
        dragSim = nil
        hoverTarget = nil
        hover(at: point)
        kick()
    }

    func cancelDrag() {
        guard let index = dragging else { return }
        dragSim?.send(.unpin(index), .alphaTarget(0))
        dragging = nil
        dragSim = nil
        hoverTarget = nil
        hoverShown = nil
        hoverProgress = 0
        kick()
    }

    func panelClosed() {
        cancelDrag()
        if !settling {
            fullSim?.halt()
            localSim?.halt()
        }
        isAnimating = false
    }

    func click(at point: CGPoint) -> String? {
        guard let index = node(at: point) else { return nil }
        let node = graph.nodes[scene.nodes[index]]
        guard !node.isGhost else { return nil }
        selected = node.id
        if localMode, let center = selectedIndex {
            fadeOutCurrent()
            buildLocalScene(around: center)
        }
        return node.path
    }

    func animateLayout() {
        scatterSeed &+= 1
        activeSim?.send(.controls(controls, reheat: 0), .scatter(scatterSeed))
        if !localMode { settling = true }
        #if DEBUG
        if !localMode { layoutStarted = CACurrentMediaTime() }
        #endif
        goal = .fit
        kick()
    }

    func controlsChanged(reheat: Float) {
        let controls = controls
        if reheat > 0 {
            activeSim?.send(.controls(controls, reheat: reheat))
            (localMode ? fullSim : localSim)?.send(.controls(controls, reheat: 0))
        }
        kick()
    }

    // MARK: Search

    private var query = ""

    func search(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if localMode, !query.isEmpty, let best = best(in: Array(graph.nodes.indices)).index {
            let id = graph.nodes[best].id
            if id != selected, let index = graph.nodes.firstIndex(where: { $0.id == id }) {
                selected = id
                cancelDrag()
                fadeOutCurrent()
                buildLocalScene(around: index)
                return
            }
        }
        refreshMatches()
        if let bestMatch { center(on: bestMatch) }
        kick()
    }

    private func refreshMatches() {
        let result = best(in: scene.nodes)
        matches = result.matches
        bestMatch = result.index
    }

    private func best(in candidates: [Int]) -> (matches: Set<Int>, index: Int?) {
        guard !query.isEmpty else { return ([], nil) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var found: Set<Int> = []
        var best: (rank: Int, degree: Int, index: Int)?
        for (i, global) in candidates.enumerated() {
            let node = graph.nodes[global]
            guard let range = node.title.range(of: query, options: options) else { continue }
            found.insert(i)
            let exact = node.title.compare(query, options: options) == .orderedSame
            let rank = exact ? 0 : range.lowerBound == node.title.startIndex ? 1 : 2
            if let current = best, current.rank < rank || (current.rank == rank && current.degree >= node.degree) { continue }
            best = (rank, node.degree, i)
        }
        return (found, best?.index)
    }

    func center(on index: Int) {
        let positions = frame.positions
        guard positions.indices.contains(index) else { return }
        let target = max(zoom, 0.9)
        let p = positions[index]
        goal = .view(zoom: target, offset: CGSize(width: -CGFloat(p.x) * target, height: -CGFloat(p.y) * target))
        kick()
    }

    // MARK: Drawing helpers

    func radius(ofScene index: Int) -> CGFloat {
        guard scene.radii.indices.contains(index) else { return 0 }
        return CGFloat(scene.radii[index] * controls.nodeSize)
    }

    func group(ofScene index: Int) -> Int {
        scene.groups.indices.contains(index) ? scene.groups[index] : folders.count
    }

    @ObservationIgnored private var sizeOrder: (version: Int, order: [Int]) = (-1, [])

    func nodesBySize() -> [Int] {
        if sizeOrder.version != scene.version {
            let radii = scene.radii
            sizeOrder = (scene.version, radii.indices.sorted { radii[$0] > radii[$1] })
        }
        return sizeOrder.order
    }

    func title(ofScene index: Int) -> String {
        graph.nodes[scene.nodes[index]].title
    }

    #if DEBUG
    func hoverForSnapshot(_ index: Int?) {
        hoverTarget = index
        hoverShown = index
        hoverProgress = index == nil ? 0 : 1
        dimProgress = index == nil && matches.isEmpty ? 0 : 1
        kick()
    }

    func finishAnimationsForSnapshot() {
        for _ in 0..<200 { advance(to: lastFrame + 0.05) }
        fade = nil
    }
    #endif
}

struct PreparedGraph: Sendable {
    var adjacency: [[Int]]
    var folders: [String]
    var groupOfNode: [Int]
    var edges: [(Int, Int)]
    var radii: [Float]
    var layout: GraphLayout

    init(scan: LinkScan, cached: GraphPositions?, onScreen: GraphPositions, paletteSlots: Int, controls: GraphControls) {
        let graph = scan.graph
        adjacency = graph.adjacency()
        folders = Array(graph.folders().filter { !$0.name.isEmpty }.prefix(paletteSlots).map(\.name))
        let slot = Dictionary(uniqueKeysWithValues: folders.enumerated().map { ($1, $0) })
        let slots = folders.count
        groupOfNode = graph.nodes.map { $0.isGhost ? -1 : slot[$0.folder] ?? slots }
        edges = graph.edges.map { ($0.a, $0.b) }
        radii = graph.nodes.map { GraphLayout.radius(degree: $0.degree) }
        let ids = graph.nodes.map(\.id)
        let seeds = GraphPositions.seeds(for: ids, previous: onScreen, cached: cached)
        let seeded = seeds.count { $0 != nil }
        let alpha: Float
        if seeded == ids.count, !ids.isEmpty {
            alpha = 0
        } else {
            alpha = seeded * 10 >= ids.count * 9 && seeded > 0 ? GraphLayout.warmAlpha : 1
        }
        layout = GraphLayout(nodeCount: ids.count, edges: graph.edges, initial: seeds, radii: radii, alpha: alpha)
        layout.apply(controls)
    }
}
