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
}
