import XCTest
@testable import WispCore

final class BrainPerfTests: XCTestCase {
    private func clock<T>(_ label: String, _ block: () throws -> T) rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try block()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("BRAINPERF \(label): \(String(format: "%.1f", ms)) ms")
        return (value, ms)
    }

    func testRealBrainTimings() throws {
        guard let root = ProcessInfo.processInfo.environment["WISP_BRAIN_PERF_ROOT"] else { throw XCTSkip("set WISP_BRAIN_PERF_ROOT to measure a real brain (read-only)") }
        let (cold, _) = clock("scan cold (tree + catalog + links)") { BrainScanner.scan(root: root) }
        let scan = try XCTUnwrap(cold)
        print("BRAINPERF notes=\(scan.catalog.notes.count) entries=\(scan.entries.count) read=\(scan.read)")
        _ = clock("scan warm (stat only, all reused)") { BrainScanner.scan(root: root, previous: scan.catalog) }
        let (index, _) = clock("tree index build (group + sort folders first)") { BrainTree.Index(entries: scan.entries) }
        let (rows, _) = clock("tree rows, root collapsed") { index.rows(expanded: []) }
        let folders = Set(scan.entries.filter(\.isFolder).map(\.path))
        let (all, _) = clock("tree rows, everything expanded") { index.rows(expanded: folders) }
        print("BRAINPERF rows collapsed=\(rows.count) expanded=\(all.count)")
        let (entries, _) = clock("switcher index build") { BrainSwitcher.entries(from: scan.catalog) }
        for query in ["", "dai", "plan", "weekly notes", "zzzq", "project plan"] {
            _ = clock("switcher rank '\(query)'") { BrainSwitcher.rank(query, in: entries, limit: 30) }
        }
        let biggest = try XCTUnwrap(scan.entries.filter { !$0.isFolder && $0.path.hasSuffix(".md") }.max { $0.size < $1.size })
        let text = try String(contentsOfFile: root + "/" + biggest.path, encoding: .utf8)
        print("BRAINPERF largest note \(biggest.size) bytes")
        let (model, _) = clock("open large note: markdown to render model") { BrainMarkdown.parse(text) }
        print("BRAINPERF blocks=\(model.nodes.count) headings=\(model.headings.count)")
        let hub = try XCTUnwrap(scan.catalog.notes.keys.max { scan.catalog.incoming(of: $0).count < scan.catalog.incoming(of: $1).count })
        let (backlinks, _) = clock("backlinks with context lines for the most linked note") {
            BrainBacklinks.find(for: hub, catalog: scan.catalog, files: BrainFiles(root: root))
        }
        print("BRAINPERF backlinks=\(backlinks.count)")
        _ = clock("rename preview (plan only) of the most linked note") {
            try? BrainRefactor.plan(root: root, scan: scan, from: hub, to: BrainText.parent(of: hub) + "/zz-perf-renamed.md")
        }
    }
}
