import Foundation
import XCTest
@testable import WispCore

final class BrainVaultFixture {
    let root: URL

    init(_ files: [String: String] = BrainVaultFixture.standard) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-brain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files { try put(path, text) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var path: String { root.path }

    func put(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func text(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: root.appendingPathComponent(path)), as: UTF8.self)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func scan(previous: BrainCatalog? = nil) throws -> BrainScan {
        try XCTUnwrap(BrainScanner.scan(root: path, previous: previous))
    }

    static let standard: [String: String] = [
        "index.md": "# Home\n\nSee [[Apple Pie]] and [[projects/garden]].\n",
        "recipes/apple-pie.md": "---\naliases: [Tarte, \"Pie\"]\ntags: [food]\nstatus: active\n---\n# Apple Pie\n\nBake it. Back to [[Home]].\n",
        "recipes/bread.md": "# Bread\n\nUses [[apple-pie#Crust|the crust]] and ![[photo.png]].\n\n```\n[[apple-pie]] in code\n```\n\nInline `[[apple-pie]]` code too.\n",
        "projects/garden.md": "# Garden\n\nPlant [[../recipes/bread]] herbs. Also [[Tarte]].\n",
        "projects/notes.md": "# Notes\n\n[[Missing note]]\n",
        "daily/2026-01-01.md": "# 1\n",
        "daily/2026-01-02.md": "# 2\n",
        "daily/2026-01-03.md": "# 3\n",
        "daily/2026-01-04.md": "# 4\n",
        "daily/2026-01-05.md": "# 5\n",
        "templates/daily.md": "---\ndate: {{date:YYYY-MM-DD}}\n---\n# {{title}}\n",
        "photo.png": "png",
        ".obsidian/app.json": "{}",
    ]
}
