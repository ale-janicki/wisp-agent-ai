import Foundation
import Testing
@testable import WispCore

@Suite struct CliScannerTests {
    private func makeBin(_ scripts: [String: String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in scripts {
            let url = dir.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return dir.path
    }

    @Test func versionLineTrimsAndCaps() {
        #expect(CliScanner.versionLine("\n  tool 1.2.3  \nsecond") == "tool 1.2.3")
        #expect(CliScanner.versionLine(" \n\n") == nil)
        let long = CliScanner.versionLine(String(repeating: "a", count: 200))
        #expect(long?.count == CliScanner.maxVersionLength)
        #expect(long?.hasSuffix("…") == true)
    }

    @Test func displayShowsHomeAsTilde() {
        #expect(CliScanner.display(directory: "/h/u/.local/bin", home: "/h/u") == "~/.local/bin")
        #expect(CliScanner.display(directory: "/h/u2/bin", home: "/h/u") == "/h/u2/bin")
        #expect(CliScanner.display(directory: "/opt/homebrew/bin", home: "/h/u") == "/opt/homebrew/bin")
    }

    @Test func scanFindsInstalledAndMissing() throws {
        let bin = try makeBin([
            "alpha": "echo 'alpha 1.0'; echo second",
            "beta": "echo 'beta 2.0' >&2",
            "authed": "case \"$1\" in --version) echo 'authed 3';; auth) exit 0;; esac",
        ])
        defer { try? FileManager.default.removeItem(atPath: bin) }
        try "not executable".write(toFile: bin + "/plain", atomically: true, encoding: .utf8)
        let tools = [CliTool("alpha"), CliTool("beta"), CliTool("plain"), CliTool("ghost"),
                     CliTool("authed", auth: .command(["auth"], needsOutput: false, label: "logado"))]
        let found = CliScanner().scan(tools: tools, path: "/nonexistent:" + bin, home: "/nowhere")
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })

        #expect(found.map(\.name) == ["alpha", "beta", "plain", "ghost", "authed"])
        #expect(byName["alpha"]?.version == "alpha 1.0")
        #expect(byName["alpha"]?.directory == bin)
        #expect(byName["beta"]?.version == "beta 2.0")
        #expect(byName["plain"]?.isInstalled == false)
        #expect(byName["ghost"]?.isInstalled == false)
        #expect(byName["authed"]?.auth == "logado")
        #expect(byName["alpha"]?.auth == nil)
    }

    @Test func authNeedsOutputWhenAsked() throws {
        let bin = try makeBin(["cloud": "case \"$1\" in --version) echo c;; *) [ -n \"$WISP_T\" ] && echo profile;; esac"])
        defer { try? FileManager.default.removeItem(atPath: bin) }
        let tool = CliTool("cloud", auth: .command(["list"], needsOutput: true, label: "perfil configurado"))
        #expect(CliScanner().scan(tools: [tool], path: bin)[0].auth == nil)
    }

    @Test func slowVersionTimesOutWithoutBlocking() throws {
        let bin = try makeBin(["slow": "/bin/sleep 5; echo late", "fast": "echo ok"])
        defer { try? FileManager.default.removeItem(atPath: bin) }
        let started = Date()
        let found = CliScanner().scan(tools: [CliTool("slow"), CliTool("fast")], path: bin, timeout: 0.3)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(found[0].isInstalled && found[0].version == nil, "\(found[0])")
        #expect(found[1].version == "ok")
    }

    @Test func resultsAreCachedUntilCleared() throws {
        let bin = try makeBin(["tool": "echo \"v $$\""])
        defer { try? FileManager.default.removeItem(atPath: bin) }
        let scanner = CliScanner()
        let first = scanner.scan(tools: [CliTool("tool")], path: bin)[0].version
        #expect(first != nil)
        #expect(scanner.scan(tools: [CliTool("tool")], path: bin)[0].version == first)
        scanner.clearCache()
        #expect(scanner.scan(tools: [CliTool("tool")], path: bin)[0].version != first)
    }

    @Test func timeoutIsNotCachedAndAuthIsNeverCached() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString)").path
        let bin = try makeBin([
            "flaky": "if [ -e \(marker) ]; then echo recovered; else /bin/sleep 5; fi",
            "authy": "case \"$1\" in --version) echo v;; *) [ -e \(marker) ] && echo p;; esac",
        ])
        defer { try? FileManager.default.removeItem(atPath: bin); try? FileManager.default.removeItem(atPath: marker) }
        let scanner = CliScanner()
        let tools = [CliTool("flaky"), CliTool("authy", auth: .command(["x"], needsOutput: true, label: "perfil configurado"))]
        let first = scanner.scan(tools: tools, path: bin, timeout: 0.3)
        #expect(first[0].version == nil && first[1].version == "v" && first[1].auth == nil)
        try "".write(toFile: marker, atomically: true, encoding: .utf8)
        let second = scanner.scan(tools: tools, path: bin, timeout: 0.3)
        #expect(second[0].version == "recovered")
        #expect(second[1].auth == "perfil configurado")
        try FileManager.default.removeItem(atPath: marker)
        #expect(scanner.scan(tools: tools, path: bin, timeout: 0.3)[1].auth == nil)
    }

    @Test func ghAuthReadsOnlyKeyPresence() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let bin = try makeBin(["gh": "echo gh 2.0"])
        defer { try? FileManager.default.removeItem(atPath: bin) }
        let tool = CliCatalog.tools.first { $0.name == "gh" }!
        #expect(CliScanner().scan(tools: [tool], path: bin, home: home)[0].auth == nil)
        try FileManager.default.createDirectory(atPath: home + "/.config/gh", withIntermediateDirectories: true)
        try "github.com:\n    git_protocol: https\n".write(toFile: home + "/.config/gh/hosts.yml", atomically: true, encoding: .utf8)
        #expect(CliScanner().scan(tools: [tool], path: bin, home: home)[0].auth == nil)
        try "github.com:\n    oauth_token: TOKENSECRET\n    user: someone\n".write(toFile: home + "/.config/gh/hosts.yml", atomically: true, encoding: .utf8)
        let status = CliScanner().scan(tools: [tool], path: bin, home: home)[0]
        #expect(status.auth == "logado")
        #expect(!String(describing: status).contains("TOKENSECRET") && !String(describing: status).contains("someone"))
    }

    @Test func catalogHasNoDuplicates() {
        let names = CliCatalog.tools.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.count == 34)
    }
}
