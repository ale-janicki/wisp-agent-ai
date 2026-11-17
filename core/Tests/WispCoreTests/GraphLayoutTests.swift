import XCTest
@testable import WispCore

final class GraphLayoutTests: XCTestCase {
    private let edges = [GraphEdge(0, 1), GraphEdge(1, 2), GraphEdge(0, 2), GraphEdge(3, 4), GraphEdge(4, 5), GraphEdge(3, 5)]

    private func distance(_ p: [SIMD2<Float>], _ a: Int, _ b: Int) -> Float {
        let d = p[a] - p[b]
        return (d * d).sum().squareRoot()
    }

    func testSettlesWithinAFewHundredStepsAndStaysFinite() {
        var layout = GraphLayout(nodeCount: 7, edges: edges)
        var steps = 0
        while !layout.isSettled && steps < 1_000 {
            layout.step()
            steps += 1
        }
        XCTAssertTrue(layout.isSettled)
        XCTAssertLessThanOrEqual(steps, 400)
        XCTAssertTrue(layout.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testLinkedNodesEndUpCloserThanUnlinkedOnes() {
        var layout = GraphLayout(nodeCount: 7, edges: edges)
        layout.settle()
        let p = layout.positions
        let inside = [distance(p, 0, 1), distance(p, 1, 2), distance(p, 3, 4), distance(p, 4, 5)]
        let across = [distance(p, 0, 3), distance(p, 1, 4), distance(p, 2, 5)]
        XCTAssertLessThan(inside.max()!, across.min()!)
        XCTAssertGreaterThan(distance(p, 0, 1), 1, "repulsion keeps neighbours apart")
    }

    func testIsDeterministic() {
        var a = GraphLayout(nodeCount: 7, edges: edges)
        var b = GraphLayout(nodeCount: 7, edges: edges)
        a.settle()
        b.settle()
        XCTAssertEqual(a.positions, b.positions)
    }

    func testBarnesHutRepulsionMatchesBruteForce() {
        let count = 400
        var layout = GraphLayout(nodeCount: count, edges: [])
        let approx = layout.chargeVelocities(theta: 0.9)
        let exact = layout.chargeVelocities(theta: 0)
        var error: Float = 0, norm: Float = 0
        for i in 0..<count {
            let d = approx[i] - exact[i]
            error += (d * d).sum()
            norm += (exact[i] * exact[i]).sum()
        }
        XCTAssertLessThan((error / norm).squareRoot(), 0.1)
        layout.step()
    }

    func testSeededPositionsBarelyMoveWhenStartedCool() {
        var first = GraphLayout(nodeCount: 7, edges: edges)
        first.settle()
        var seeds: [SIMD2<Float>?] = first.positions.map { $0 }
        seeds.append(nil)
        var next = GraphLayout(nodeCount: 8, edges: edges + [GraphEdge(6, 7)], initial: seeds, alpha: GraphLayout.warmAlpha)
        XCTAssertLessThan(distance(next.positions, 6, 7), 40, "a new node starts next to its seeded neighbour")
        next.settle()
        for i in 0..<6 {
            let d = next.positions[i] - first.positions[i]
            XCTAssertLessThan((d * d).sum().squareRoot(), 30)
        }
    }

    func testPositionsRoundTripThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-pos-\(UUID().uuidString)/positions.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let saved = GraphPositions(root: "/v", ids: ["a.md", "b.md"], positions: [SIMD2(1.5, -2), SIMD2(3, 4.25)])
        try saved.save(to: url)
        let loaded = try XCTUnwrap(GraphPositions.load(from: url))
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(loaded.seeds(for: ["b.md", "c.md"]), [SIMD2(3, 4.25), nil])
    }

    func testSeedingManyIdsIsLinearNotQuadratic() {
        let ids = (0..<3_000).map { "note-\($0).md" }
        let points = ids.indices.map { SIMD2(Float($0), Float(-$0)) }
        let cached = GraphPositions(root: "/v", ids: ids, positions: points)
        let previous = GraphPositions(root: "/v", ids: Array(ids.prefix(100)), positions: Array(points.prefix(100)).map { $0 + SIMD2(1, 1) })
        let started = ContinuousClock.now
        let seeds = GraphPositions.seeds(for: ids + ["new.md"], previous: previous, cached: cached)
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .milliseconds(50))
        XCTAssertEqual(seeds.count, 3_001)
        XCTAssertEqual(seeds[0], SIMD2(1, 1), "previous wins over cached")
        XCTAssertEqual(seeds[200], points[200])
        XCTAssertNil(seeds[3_000])
    }

    // MARK: Live simulation

    private func ring(_ count: Int) -> [GraphEdge] {
        (0..<count).map { GraphEdge($0, ($0 + 1) % count) } + [GraphEdge(0, count / 2)]
    }

    func testKineticEnergyDiesDownAsTheSimulationCools() {
        var layout = GraphLayout(nodeCount: 60, edges: ring(60))
        var energies: [Float] = []
        while !layout.isSettled && energies.count < 1_000 {
            layout.step()
            energies.append(layout.kineticEnergy)
        }
        let peak = energies.max() ?? 0
        XCTAssertGreaterThan(peak, 0)
        XCTAssertLessThan(energies.suffix(20).max() ?? .infinity, peak * 0.01)
        let tail = Array(energies[(energies.count / 2)...])
        let rises = zip(tail.dropFirst(), tail).filter { $0 > $1 * 1.05 }.count
        XCTAssertLessThan(rises, tail.count / 10, "energy keeps falling once the layout has formed")
    }

    func testAlphaDecaysToAStopInAboutThreeHundredTicks() {
        var layout = GraphLayout(nodeCount: 7, edges: edges)
        var ticks = 0
        while !layout.isSettled && ticks < 1_000 {
            layout.step()
            ticks += 1
        }
        XCTAssertTrue((295...305).contains(ticks), "\(ticks) ticks")
        XCTAssertLessThan(layout.alpha, GraphLayout.alphaMin)
        let rest = layout.positions
        layout.step()
        XCTAssertEqual(layout.positions, rest, "a settled simulation does not drift when stepped")
    }

    func testPinnedNodeStaysUnderTheCursorAndPullsItsNeighbours() {
        var layout = GraphLayout(nodeCount: 7, edges: edges)
        layout.settle()
        let cursor = SIMD2<Float>(400, -250)
        let before = layout.positions[1] - cursor
        layout.pin(0, at: cursor)
        layout.alphaTarget = 0.3
        layout.reheat(to: 0.3)
        for _ in 0..<300 {
            layout.step()
            XCTAssertEqual(layout.positions[0], cursor)
        }
        XCTAssertFalse(layout.isSettled, "alphaTarget keeps the simulation warm while dragging")
        XCTAssertEqual(layout.alpha, 0.3, accuracy: 0.01)
        let after = layout.positions[1] - cursor
        XCTAssertLessThan((after * after).sum(), (before * before).sum() * 0.25, "the springs pulled the neighbour at least halfway")
        XCTAssertGreaterThan(distance(layout.positions, 0, 3), distance(layout.positions, 0, 1), "the other triangle is not attached")
        layout.unpin(0)
        layout.alphaTarget = 0
        layout.settle()
        XCTAssertTrue(layout.isSettled, "released, the simulation cools back to rest")
    }

    func testReheatWakesASettledSimulation() {
        var layout = GraphLayout(nodeCount: 7, edges: edges)
        layout.settle()
        XCTAssertTrue(layout.isSettled)
        layout.reheat(to: 0.3)
        XCTAssertFalse(layout.isSettled)
        XCTAssertEqual(layout.alpha, 0.3)
        layout.reheat(to: 0.1)
        XCTAssertEqual(layout.alpha, 0.3, "reheat never cools")
    }

    func testBarnesHutMatchesBruteForceOnASmallClusteredGraph() {
        let count = 48
        let seeds: [SIMD2<Float>?] = (0..<count).map { i in
            let cluster = Float(i % 3) * 120
            return SIMD2(cluster + Float(i % 7) * 3, Float(i / 7) * 4 - cluster / 2)
        }
        let layout = GraphLayout(nodeCount: count, edges: ring(count), initial: seeds)
        let approx = layout.chargeVelocities(theta: 0.9)
        let exact = layout.chargeVelocities(theta: 0)
        for i in 0..<count {
            let d = approx[i] - exact[i]
            let error = (d * d).sum().squareRoot(), size = (exact[i] * exact[i]).sum().squareRoot()
            XCTAssertLessThan(error, max(size * 0.2, 1e-3), "node \(i)")
        }
    }

    func testCollisionPushesOverlappingNodesApart() {
        var layout = GraphLayout(nodeCount: 2, edges: [], initial: [SIMD2(0, 0), SIMD2(1, 0)], radii: [10, 10])
        layout.charge = 0
        layout.gravity = 0
        for _ in 0..<120 { layout.step() }
        XCTAssertGreaterThan(distance(layout.positions, 0, 1), 18)
    }

    func testScatterRestartsHotFromSpreadPositions() {
        var layout = GraphLayout(nodeCount: 30, edges: ring(30))
        layout.settle()
        let rest = layout.positions
        layout.scatter(seed: 7)
        XCTAssertEqual(layout.alpha, 1)
        XCTAssertNotEqual(layout.positions, rest)
        XCTAssertEqual(layout.kineticEnergy, 0)
        var again = GraphLayout(nodeCount: 30, edges: ring(30))
        again.settle()
        again.scatter(seed: 7)
        XCTAssertEqual(again.positions, layout.positions, "same seed, same scatter")
    }

    func testControlsMapOntoTheForces() {
        var layout = GraphLayout(nodeCount: 3, edges: [GraphEdge(0, 1)])
        var controls = GraphControls()
        controls.center = 1
        controls.repel = 20
        controls.link = 0.5
        controls.linkDistance = 120
        layout.apply(controls)
        XCTAssertEqual(layout.gravity, 2 * GraphControls.defaultGravity, accuracy: 1e-6)
        XCTAssertEqual(layout.charge, 2 * GraphControls.defaultCharge, accuracy: 1e-6)
        XCTAssertEqual(layout.linkScale, 0.5)
        XCTAssertEqual(layout.linkDistance, 120)
        layout.apply(GraphControls())
        XCTAssertEqual(layout.gravity, GraphControls.defaultGravity, accuracy: 1e-6)
        XCTAssertEqual(layout.charge, GraphControls.defaultCharge, accuracy: 1e-6)
    }
}
