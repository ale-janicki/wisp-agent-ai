import Foundation
import Observation
import SwiftUI
import WispCore

struct GraphScene {
    var nodes: [Int] = []
    var positions: [CGPoint] = []
    var edges: [(Int, Int)] = []
    var adjacency: [[Int]] = []
    var version = 0

    var isEmpty: Bool { nodes.isEmpty }

    var bounds: CGRect {
        guard let first = positions.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in positions {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
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

    private(set) var phase: Phase = .idle
    private(set) var graph: LinkGraph = .empty
    private(set) var scene = GraphScene()
    private(set) var settling = false
    private(set) var placeholders = 0
    private(set) var folders: [String] = []

    var offset: CGSize = .zero
    var zoom: CGFloat = 1
    var hovered: Int?
    private(set) var matches: Set<Int> = []
    private(set) var bestMatch: Int?
    private(set) var selected: String?
    private(set) var localMode = false
    var showGhosts = false {
        didSet { if oldValue != showGhosts, let root { load(root: root, force: true) } }
    }

    @ObservationIgnored private var root: String?
    @ObservationIgnored private var scannedRoot: String?
    @ObservationIgnored private var localTask: Task<Void, Never>?
    @ObservationIgnored private var adjacency: [[Int]] = []
    @ObservationIgnored private var fullPositions: [CGPoint] = []
    @ObservationIgnored private var groupOfNode: [Int] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var layoutTask: Task<Void, Never>?
    @ObservationIgnored private var lastLoad: Date?
    @ObservationIgnored private var autoFit = true
    @ObservationIgnored private var viewSize: CGSize = .zero
    @ObservationIgnored let paths = GraphPathCache()
    private(set) var edgePaths: [Path] = []
    private(set) var edgePathsVersion = -1
    @ObservationIgnored private var edgeTask: Task<Void, Never>?
    @ObservationIgnored private var fullEdges: [(Int, Int)] = []

    #if DEBUG
    @ObservationIgnored private(set) var lastScanSeconds: Double?
    @ObservationIgnored private(set) var lastLayoutSeconds: Double?
    @ObservationIgnored private(set) var lastScanStats: LinkScanStats?
    @ObservationIgnored private(set) var scansApplied = 0
    #endif

    nonisolated private static var directory: URL {
        ConversationStore.defaultDirectory.appendingPathComponent("graph", isDirectory: true)
    }

    nonisolated private static var linksURL: URL { directory.appendingPathComponent("links.json") }
    nonisolated private static var positionsURL: URL { directory.appendingPathComponent("positions.json") }

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
        let onScreen = GraphPositions(
            root: "",
            ids: graph.nodes.map(\.id),
            positions: fullPositions.map { SIMD2(Float($0.x), Float($0.y)) }
        )
        let paletteSlots = Theme.Graph.palette.count
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
                    return (scan, PreparedGraph(scan: scan, cached: positions, onScreen: onScreen, paletteSlots: paletteSlots))
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
        fullEdges = prepared.edges
        let ids = graph.nodes.map(\.id)
        let seeds = prepared.seeds
        let seededCount = prepared.seededCount
        fullPositions = prepared.positions
        phase = .ready
        rebuildScene()
        if seededCount == ids.count, !ids.isEmpty { return }
        let alpha: Float = seededCount * 10 >= ids.count * 9 && seededCount > 0 ? GraphLayout.warmAlpha : 1
        layoutTask?.cancel()
        settling = true
        layoutTask = runLayout(nodeCount: ids.count, edges: graph.edges, seeds: seeds, alpha: alpha) { [weak self] points, seconds in
            guard let self, self.generation == current else { return }
            self.fullPositions = points
            if let seconds {
                self.settling = false
                #if DEBUG
                self.lastLayoutSeconds = seconds
                #endif
                self.savePositions()
            }
            if !self.localMode { self.rebuildScene() }
        }
    }

    private func runLayout(
        nodeCount: Int,
        edges: [GraphEdge],
        seeds: [SIMD2<Float>?],
        alpha: Float,
        publish: @escaping @MainActor @Sendable ([CGPoint], Double?) -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            let started = ContinuousClock.now
            var layout = GraphLayout(nodeCount: nodeCount, edges: edges, initial: seeds, alpha: alpha)
            var published = ContinuousClock.now
            while !layout.isSettled {
                if Task.isCancelled { return }
                layout.step()
                if published.duration(to: .now) > .milliseconds(100) {
                    let points = Self.points(layout.positions)
                    await MainActor.run { if !Task.isCancelled { publish(points, nil) } }
                    published = .now
                }
            }
            let points = Self.points(layout.positions)
            let seconds = Self.seconds(since: started)
            await MainActor.run { if !Task.isCancelled { publish(points, seconds) } }
        }
    }

    nonisolated private static func points(_ positions: [SIMD2<Float>]) -> [CGPoint] {
        positions.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
    }

    nonisolated private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    private func savePositions() {
        let ids = graph.nodes.map(\.id)
        let points = fullPositions.map { SIMD2(Float($0.x), Float($0.y)) }
        guard let scannedRoot else { return }
        let snapshot = GraphPositions(root: scannedRoot, ids: ids, positions: points)
        Task.detached(priority: .utility) { try? snapshot.save(to: Self.positionsURL) }
    }

    // MARK: Scene

    private func rebuildScene() {
        let version = scene.version + 1
        let previous = scene
        if localMode, let center = selectedIndex {
            buildLocalScene(around: center, version: version)
        } else {
            scene = GraphScene(
                nodes: Array(graph.nodes.indices),
                positions: fullPositions,
                edges: fullEdges,
                adjacency: adjacency,
                version: version
            )
            refreshMatches()
            if autoFit { fit() }
        }
        if previous.nodes != scene.nodes || previous.edges.count != scene.edges.count { edgePaths = [] }
        rebuildEdgePaths()
    }

    private func rebuildEdgePaths() {
        let version = scene.version
        let edges = scene.edges
        let positions = scene.positions
        edgeTask?.cancel()
        edgeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let chunks = GraphPathCache.edgeChunks(edges: edges, positions: positions) else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled, self.scene.version == version else { return }
                self.edgePaths = chunks
                self.edgePathsVersion = version
            }
        }
    }

    var selectedSceneIndex: Int? {
        guard localMode, let selected else { return nil }
        return scene.nodes.firstIndex { graph.nodes[$0].id == selected }
    }

    private var selectedIndex: Int? {
        guard let selected else { return nil }
        return graph.nodes.firstIndex { $0.id == selected }
    }

    private func buildLocalScene(around center: Int, version: Int) {
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
        let layout = GraphLayout(nodeCount: members.count, edges: edges)
        scene = GraphScene(
            nodes: members,
            positions: Self.points(layout.positions),
            edges: edges.map { ($0.a, $0.b) },
            adjacency: adjacency,
            version: version
        )
        autoFit = true
        refreshMatches()
        fit()
        localTask?.cancel()
        localTask = runLayout(nodeCount: members.count, edges: edges, seeds: [], alpha: 1) { [weak self] points, _ in
            guard let self, self.localMode, self.scene.nodes == members else { return }
            self.scene.positions = points
            self.scene.version += 1
            self.rebuildEdgePaths()
            if self.autoFit { self.fit() }
        }
    }

    func setLocalMode(_ on: Bool, fallback: String?) {
        if on, selected == nil { selected = fallback }
        if !on && !localMode { return }
        localMode = on && selectedIndex != nil
        hovered = nil
        autoFit = true
        if !localMode { localTask?.cancel() }
        rebuildScene()
    }

    // MARK: Interaction

    func setViewSize(_ size: CGSize) {
        guard size != viewSize else { return }
        viewSize = size
        if autoFit { fit() }
    }

    func fit() {
        guard !scene.isEmpty, viewSize.width > 0, viewSize.height > 0 else { return }
        let bounds = scene.bounds.insetBy(dx: -12, dy: -12)
        let usable = CGSize(width: viewSize.width - 24, height: viewSize.height - 2 * Self.overlayInset)
        let scale = min(usable.width / max(bounds.width, 1), max(usable.height, 40) / max(bounds.height, 1))
        zoom = min(max(scale, Self.zoomRange.lowerBound), 2.5)
        offset = CGSize(width: -bounds.midX * zoom, height: -bounds.midY * zoom)
    }

    func userMovedViewport() { autoFit = false }

    func pan(by delta: CGSize) {
        autoFit = false
        offset.width += delta.width
        offset.height += delta.height
    }

    func zoom(by factor: CGFloat, at anchor: CGPoint?) {
        autoFit = false
        let next = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let point = anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let world = toWorld(point)
        zoom = next
        offset = CGSize(
            width: point.x - viewSize.width / 2 - world.x * next,
            height: point.y - viewSize.height / 2 - world.y * next
        )
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

    func node(at point: CGPoint) -> Int? {
        let world = toWorld(point)
        var best: Int?
        var bestDistance = CGFloat.infinity
        for (i, p) in scene.positions.enumerated() {
            let dx = p.x - world.x, dy = p.y - world.y
            let distance = dx * dx + dy * dy
            let reach = (radius(ofScene: i) * zoom + 4) / zoom
            if distance < reach * reach, distance < bestDistance {
                best = i
                bestDistance = distance
            }
        }
        return best
    }

    func hover(at point: CGPoint?) {
        let next = point.flatMap(node(at:))
        if next != hovered { hovered = next }
    }

    func click(at point: CGPoint) -> String? {
        guard let index = node(at: point) else { return nil }
        let node = graph.nodes[scene.nodes[index]]
        guard !node.isGhost else { return nil }
        selected = node.id
        if localMode { rebuildScene() }
        return node.path
    }

    // MARK: Search

    private var query = ""

    func search(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if localMode, !query.isEmpty, let best = best(in: Array(graph.nodes.indices)).index {
            let id = graph.nodes[best].id
            if id != selected {
                selected = id
                rebuildScene()
                return
            }
        }
        refreshMatches()
        if let bestMatch { center(on: bestMatch) }
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
        guard scene.positions.indices.contains(index) else { return }
        autoFit = false
        let target = max(zoom, 0.9)
        let p = scene.positions[index]
        zoom = target
        offset = CGSize(width: -p.x * target, height: -p.y * target)
    }

    // MARK: Drawing helpers

    func radius(ofScene index: Int) -> CGFloat {
        Self.radius(degree: graph.nodes[scene.nodes[index]].degree)
    }

    static func radius(degree: Int) -> CGFloat {
        2.5 + CGFloat(Double(degree).squareRoot()) * 0.9
    }

    func group(ofScene index: Int) -> Int {
        let global = scene.nodes[index]
        return groupOfNode.indices.contains(global) ? groupOfNode[global] : folders.count
    }

    func title(ofScene index: Int) -> String {
        graph.nodes[scene.nodes[index]].title
    }

    #if DEBUG
    func selectForSnapshot(_ id: String) {
        selected = id
    }
    #endif
}

@MainActor
final class GraphPathCache {
    private(set) var nodes: [Int: Path] = [:]
    private var nodeKey: (version: Int, zoom: CGFloat) = (-1, 0)

    static let minimumScreenRadius: CGFloat = 1.6
    nonisolated static let edgeChunk = 16

    nonisolated static func edgeChunks(edges: [(Int, Int)], positions: [CGPoint]) -> [Path]? {
        var chunks: [Path] = []
        chunks.reserveCapacity(edges.count / edgeChunk + 1)
        var chunk = Path()
        for (k, (a, b)) in edges.enumerated() {
            if k % 1024 == 0, Task.isCancelled { return nil }
            chunk.move(to: positions[a])
            chunk.addLine(to: positions[b])
            if k % edgeChunk == edgeChunk - 1 {
                chunks.append(chunk)
                chunk = Path()
            }
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    func update(_ model: MemoryGraphModel) {
        let scene = model.scene
        if nodeKey.version != scene.version || nodeKey.zoom != model.zoom {
            var groups: [Int: Path] = [:]
            let floor = Self.minimumScreenRadius / model.zoom
            for (i, p) in scene.positions.enumerated() {
                let r = max(model.radius(ofScene: i), floor)
                groups[model.group(ofScene: i), default: Path()].addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
            nodes = groups
            nodeKey = (scene.version, model.zoom)
        }
    }
}

struct PreparedGraph: Sendable {
    var adjacency: [[Int]]
    var folders: [String]
    var groupOfNode: [Int]
    var edges: [(Int, Int)]
    var seeds: [SIMD2<Float>?]
    var seededCount: Int
    var positions: [CGPoint]

    init(scan: LinkScan, cached: GraphPositions?, onScreen: GraphPositions, paletteSlots: Int) {
        let graph = scan.graph
        adjacency = graph.adjacency()
        folders = Array(graph.folders().filter { !$0.name.isEmpty }.prefix(paletteSlots).map(\.name))
        let slot = Dictionary(uniqueKeysWithValues: folders.enumerated().map { ($1, $0) })
        let slots = folders.count
        groupOfNode = graph.nodes.map { $0.isGhost ? -1 : slot[$0.folder] ?? slots }
        edges = graph.edges.map { ($0.a, $0.b) }
        let ids = graph.nodes.map(\.id)
        seeds = GraphPositions.seeds(for: ids, previous: onScreen, cached: cached)
        seededCount = seeds.count { $0 != nil }
        let initial = GraphLayout(nodeCount: ids.count, edges: graph.edges, initial: seeds)
        positions = initial.positions.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
    }
}
