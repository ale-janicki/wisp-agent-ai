import Foundation

public struct GraphLayout: Sendable {
    public static let alphaMin: Float = 0.001
    public static let alphaDecay: Float = 1 - powf(0.001, 1 / 300)
    public static let warmAlpha: Float = 0.1

    public var linkDistance: Float = 30
    public var charge: Float = -30
    public var gravity: Float = 0.08
    public var theta: Float = 0.9
    public var velocityDecay: Float = 0.4

    public private(set) var alpha: Float
    private var x: [Float], y: [Float], vx: [Float], vy: [Float]
    private let sources: [Int32], targets: [Int32]
    private let strengths: [Float], biases: [Float]

    public var isSettled: Bool { alpha < Self.alphaMin }
    public var count: Int { x.count }

    public var positions: [SIMD2<Float>] {
        (0..<x.count).map { SIMD2(x[$0], y[$0]) }
    }

    public init(nodeCount: Int, edges: [GraphEdge], initial: [SIMD2<Float>?] = [], alpha: Float = 1) {
        self.alpha = alpha
        var degree = Array(repeating: 0, count: nodeCount)
        var neighbors = Array(repeating: [Int](), count: nodeCount)
        var sources: [Int32] = [], targets: [Int32] = []
        for edge in edges where edge.a < nodeCount && edge.b < nodeCount {
            sources.append(Int32(edge.a))
            targets.append(Int32(edge.b))
            degree[edge.a] += 1
            degree[edge.b] += 1
            neighbors[edge.a].append(edge.b)
            neighbors[edge.b].append(edge.a)
        }
        self.sources = sources
        self.targets = targets
        strengths = zip(sources, targets).map { 1 / Float(min(degree[Int($0)], degree[Int($1)])) }
        biases = zip(sources, targets).map { Float(degree[Int($0)]) / Float(degree[Int($0)] + degree[Int($1)]) }

        var px = Array(repeating: Float(0), count: nodeCount), py = px
        var placed = Array(repeating: false, count: nodeCount)
        for i in 0..<nodeCount {
            if i < initial.count, let seed = initial[i] {
                px[i] = seed.x
                py[i] = seed.y
                placed[i] = true
            }
        }
        let golden = Float.pi * (3 - Float(5).squareRoot())
        for i in 0..<nodeCount where !placed[i] {
            let angle = Float(i) * golden
            if let anchor = neighbors[i].first(where: { placed[$0] }) {
                px[i] = px[anchor] + 12 * cosf(angle)
                py[i] = py[anchor] + 12 * sinf(angle)
            } else {
                let radius = 10 * (0.5 + Float(i)).squareRoot()
                px[i] = radius * cosf(angle)
                py[i] = radius * sinf(angle)
            }
        }
        x = px
        y = py
        vx = Array(repeating: 0, count: nodeCount)
        vy = vx
    }

    public mutating func step() {
        guard !x.isEmpty else {
            alpha = 0
            return
        }
        alpha += (0 - alpha) * Self.alphaDecay
        applyLinks()
        applyCharge(theta: theta)
        let pull = gravity * alpha
        let keep = 1 - velocityDecay
        for i in 0..<x.count {
            vx[i] -= x[i] * pull
            vy[i] -= y[i] * pull
            vx[i] *= keep
            vy[i] *= keep
            x[i] += vx[i]
            y[i] += vy[i]
        }
    }

    public mutating func settle(maxSteps: Int = 1_000) {
        var steps = 0
        while !isSettled && steps < maxSteps {
            step()
            steps += 1
        }
    }

    private mutating func applyLinks() {
        for k in 0..<sources.count {
            let s = Int(sources[k]), t = Int(targets[k])
            var dx = x[t] + vx[t] - x[s] - vx[s]
            var dy = y[t] + vy[t] - y[s] - vy[s]
            if dx == 0 { dx = Self.jiggle(k) }
            if dy == 0 { dy = Self.jiggle(k + 1) }
            let length = (dx * dx + dy * dy).squareRoot()
            let pull = (length - linkDistance) / length * alpha * strengths[k]
            dx *= pull
            dy *= pull
            let bias = biases[k]
            vx[t] -= dx * bias
            vy[t] -= dy * bias
            vx[s] += dx * (1 - bias)
            vy[s] += dy * (1 - bias)
        }
    }

    private mutating func applyCharge(theta: Float) {
        let force = QuadTree(x: x, y: y).forces(x: x, y: y, thetaSquared: theta * theta)
        let scale = charge * alpha
        for i in 0..<x.count {
            vx[i] += force.x[i] * scale
            vy[i] += force.y[i] * scale
        }
    }

    func chargeVelocities(theta: Float) -> [SIMD2<Float>] {
        let force = QuadTree(x: x, y: y).forces(x: x, y: y, thetaSquared: theta * theta)
        return (0..<x.count).map { SIMD2(force.x[$0], force.y[$0]) * charge * alpha }
    }

    static func jiggle(_ seed: Int) -> Float {
        (Float(seed % 13) - 6) * 1e-4 + 1e-6
    }
}

private struct QuadTree {
    static let distanceMinSquared: Float = 1
    static let maxDepth = 40

    private var originX: [Float] = [], originY: [Float] = [], width: [Float] = []
    private var firstChild: [Int32] = []
    private var head: [Int32] = []
    private var massX: [Float] = [], massY: [Float] = [], mass: [Float] = []
    private var next: [Int32]

    init(x: [Float], y: [Float]) {
        next = Array(repeating: -1, count: x.count)
        guard var minX = x.first, var minY = y.first else { return }
        var maxX = minX, maxY = minY
        for i in 0..<x.count {
            minX = min(minX, x[i])
            maxX = max(maxX, x[i])
            minY = min(minY, y[i])
            maxY = max(maxY, y[i])
        }
        let side = max(maxX - minX, maxY - minY, 1) * 1.0001
        let capacity = x.count * 2 + 1
        originX.reserveCapacity(capacity)
        originY.reserveCapacity(capacity)
        width.reserveCapacity(capacity)
        firstChild.reserveCapacity(capacity)
        head.reserveCapacity(capacity)
        addCell(minX, minY, side)
        for i in 0..<x.count { insert(i, x: x, y: y) }
        summarize(x: x, y: y)
    }

    private mutating func addCell(_ ox: Float, _ oy: Float, _ side: Float) {
        originX.append(ox)
        originY.append(oy)
        width.append(side)
        firstChild.append(-1)
        head.append(-1)
    }

    private func quadrant(of cell: Int, _ px: Float, _ py: Float) -> Int {
        let half = width[cell] / 2
        return (px >= originX[cell] + half ? 1 : 0) + (py >= originY[cell] + half ? 2 : 0)
    }

    private mutating func split(_ cell: Int) {
        let half = width[cell] / 2
        firstChild[cell] = Int32(originX.count)
        for q in 0..<4 {
            addCell(originX[cell] + (q & 1 == 1 ? half : 0), originY[cell] + (q & 2 == 2 ? half : 0), half)
        }
    }

    private mutating func insert(_ point: Int, x: [Float], y: [Float]) {
        var cell = 0
        var depth = 0
        while true {
            if firstChild[cell] >= 0 {
                cell = Int(firstChild[cell]) + quadrant(of: cell, x[point], y[point])
                depth += 1
                continue
            }
            let resident = Int(head[cell])
            if resident < 0 {
                head[cell] = Int32(point)
                return
            }
            if depth >= Self.maxDepth || (x[resident] == x[point] && y[resident] == y[point]) {
                next[point] = head[cell]
                head[cell] = Int32(point)
                return
            }
            split(cell)
            head[cell] = -1
            var moving = resident
            while moving >= 0 {
                let following = Int(next[moving])
                next[moving] = -1
                let child = Int(firstChild[cell]) + quadrant(of: cell, x[moving], y[moving])
                next[moving] = head[child]
                head[child] = Int32(moving)
                moving = following
            }
        }
    }

    private mutating func summarize(x: [Float], y: [Float]) {
        let cells = originX.count
        massX = Array(repeating: 0, count: cells)
        massY = massX
        mass = massX
        for cell in stride(from: cells - 1, through: 0, by: -1) {
            if firstChild[cell] >= 0 {
                let first = Int(firstChild[cell])
                var m: Float = 0, sx: Float = 0, sy: Float = 0
                for child in first..<first + 4 where mass[child] > 0 {
                    m += mass[child]
                    sx += massX[child] * mass[child]
                    sy += massY[child] * mass[child]
                }
                mass[cell] = m
                if m > 0 {
                    massX[cell] = sx / m
                    massY[cell] = sy / m
                }
            } else {
                var point = Int(head[cell])
                var m: Float = 0, sx: Float = 0, sy: Float = 0
                while point >= 0 {
                    m += 1
                    sx += x[point]
                    sy += y[point]
                    point = Int(next[point])
                }
                mass[cell] = m
                if m > 0 {
                    massX[cell] = sx / m
                    massY[cell] = sy / m
                }
            }
        }
    }

    func forces(x: [Float], y: [Float], thetaSquared: Float) -> (x: [Float], y: [Float]) {
        let count = x.count
        var outX = [Float](repeating: 0, count: count), outY = outX
        guard !mass.isEmpty else { return (outX, outY) }
        let chunks = min(count, ProcessInfo.processInfo.activeProcessorCount * 4)
        outX.withUnsafeMutableBufferPointer { outX in
            outY.withUnsafeMutableBufferPointer { outY in
                let out = Output(x: outX.baseAddress!, y: outY.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let range = (count * chunk / chunks)..<(count * (chunk + 1) / chunks)
                    walk(range, x: x, y: y, thetaSquared: thetaSquared, out: out)
                }
            }
        }
        return (outX, outY)
    }

    private struct Output: @unchecked Sendable {
        let x: UnsafeMutablePointer<Float>
        let y: UnsafeMutablePointer<Float>
    }

    private func walk(_ range: Range<Int>, x: [Float], y: [Float], thetaSquared: Float, out: Output) {
        let stack = UnsafeMutablePointer<Int32>.allocate(capacity: 4 * Self.maxDepth + 8)
        defer { stack.deallocate() }
        x.withUnsafeBufferPointer { x in
            y.withUnsafeBufferPointer { y in
                mass.withUnsafeBufferPointer { mass in
                    massX.withUnsafeBufferPointer { massX in
                        massY.withUnsafeBufferPointer { massY in
                            width.withUnsafeBufferPointer { width in
                                firstChild.withUnsafeBufferPointer { firstChild in
                                    head.withUnsafeBufferPointer { head in
                                        next.withUnsafeBufferPointer { next in
                                            for i in range {
                                                let px = x[i], py = y[i]
                                                var fx: Float = 0, fy: Float = 0
                                                var depth = 1
                                                stack[0] = 0
                                                while depth > 0 {
                                                    depth -= 1
                                                    let cell = Int(stack[depth])
                                                    let m = mass[cell]
                                                    guard m > 0 else { continue }
                                                    let first = firstChild[cell]
                                                    if first >= 0 {
                                                        let dx = massX[cell] - px, dy = massY[cell] - py
                                                        var distance = dx * dx + dy * dy
                                                        let w = width[cell]
                                                        if thetaSquared > 0 && w * w < distance * thetaSquared {
                                                            if distance < Self.distanceMinSquared { distance = (Self.distanceMinSquared * distance).squareRoot() }
                                                            let k = m / distance
                                                            fx += dx * k
                                                            fy += dy * k
                                                            continue
                                                        }
                                                        stack[depth] = first
                                                        stack[depth + 1] = first + 1
                                                        stack[depth + 2] = first + 2
                                                        stack[depth + 3] = first + 3
                                                        depth += 4
                                                        continue
                                                    }
                                                    var point = Int(head[cell])
                                                    while point >= 0 {
                                                        if point != i {
                                                            var dx = x[point] - px, dy = y[point] - py
                                                            if dx == 0 { dx = GraphLayout.jiggle(i + point) }
                                                            if dy == 0 { dy = GraphLayout.jiggle(i * 3 + point) }
                                                            var distance = dx * dx + dy * dy
                                                            if distance < Self.distanceMinSquared { distance = (Self.distanceMinSquared * distance).squareRoot() }
                                                            fx += dx / distance
                                                            fy += dy / distance
                                                        }
                                                        point = Int(next[point])
                                                    }
                                                }
                                                out.x[i] = fx
                                                out.y[i] = fy
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

public struct GraphPositions: Codable, Sendable, Equatable {
    public var root: String
    public var ids: [String]
    public var positions: [SIMD2<Float>]

    public init(root: String, ids: [String], positions: [SIMD2<Float>]) {
        self.root = root
        self.ids = ids
        self.positions = positions
    }

    public static func load(from url: URL) -> GraphPositions? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GraphPositions.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public func seeds(for nodeIds: [String]) -> [SIMD2<Float>?] {
        let lookup = lookup()
        return nodeIds.map { lookup[$0] }
    }

    public static func seeds(for nodeIds: [String], previous: GraphPositions?, cached: GraphPositions?) -> [SIMD2<Float>?] {
        let fresh = previous?.lookup() ?? [:]
        let saved = cached?.lookup() ?? [:]
        return nodeIds.map { fresh[$0] ?? saved[$0] }
    }

    private func lookup() -> [String: SIMD2<Float>] {
        var lookup: [String: SIMD2<Float>] = [:]
        lookup.reserveCapacity(ids.count)
        for (id, point) in zip(ids, positions) { lookup[id] = point }
        return lookup
    }
}
