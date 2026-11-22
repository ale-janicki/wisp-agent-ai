import Foundation
import Testing

@testable import WispCore

@Suite struct EngineConnectTests {
    @Test func commandsAreFixedPerEngine() {
        #expect(EngineLogin.claude.command == "claude")
        #expect(EngineLogin.codex.command == "codex login")
        #expect(EngineLogin(.claude)?.kind == .claude)
        #expect(EngineLogin(.codex)?.kind == .codex)
        #expect(EngineLogin(.local) == nil)
    }

    @Test func scriptRunsOnlyTheFixedCommand() {
        let lines = EngineLogin.codex.script.split(separator: "\n").map(String.init)
        #expect(lines.first == "#!/bin/zsh -l")
        #expect(lines.last == "codex login")
        #expect(EngineLogin.claude.script.hasSuffix("\nclaude\n"))
    }

    @Test func commandFileNamesAreRecognised() {
        let name = EngineLogin.claude.commandFileName(token: "abc")
        #expect(name == "wisp-connect-claude-abc.command")
        #expect(EngineLogin.isCommandFile(name))
        #expect(!EngineLogin.isCommandFile("notes.command"))
        #expect(!EngineLogin.isCommandFile("wisp-connect-claude-abc.txt"))
    }

    @Test func installHelp() {
        #expect(EngineLogin.claude.installCommand == "curl -fsSL https://claude.ai/install.sh | bash")
        #expect(EngineLogin.codex.installCommand == nil)
        #expect(EngineLogin.codex.installURL.scheme == "https")
    }

    @Test func resolveFollowsInstallAndLogin() {
        #expect(EngineConnectFlow.resolve(installed: false, loggedIn: false) == .notInstalled)
        #expect(EngineConnectFlow.resolve(installed: false, loggedIn: true) == .notInstalled)
        #expect(EngineConnectFlow.resolve(installed: true, loggedIn: false) == .notConnected)
        #expect(EngineConnectFlow.resolve(installed: true, loggedIn: true) == .connected)
    }

    @Test func openingWaitsThenConnects() {
        var flow = EngineConnectFlow()
        flow.check(installed: true, loggedIn: false)
        #expect(flow.state == .notConnected)
        flow.opened()
        #expect(flow.state == .waiting)
        flow.polled(loggedIn: false)
        #expect(flow.state == .waiting)
        flow.polled(loggedIn: true)
        #expect(flow.state == .connected)
    }

    @Test func notInstalledNeverOpens() {
        var flow = EngineConnectFlow()
        flow.check(installed: false, loggedIn: false)
        flow.opened()
        #expect(flow.state == .notInstalled)
    }

    @Test func timesOutAfterTenMinutesAndCanRetry() {
        var flow = EngineConnectFlow(state: .notConnected)
        flow.opened()
        for _ in 0..<199 { flow.polled(loggedIn: false) }
        #expect(flow.state == .waiting)
        flow.polled(loggedIn: false)
        #expect(flow.state == .timedOut)
        flow.polled(loggedIn: true)
        #expect(flow.state == .timedOut)
        flow.opened()
        #expect(flow.state == .waiting)
        flow.polled(loggedIn: true)
        #expect(flow.state == .connected)
    }

    @Test func aRecheckWhileWaitingKeepsWaiting() {
        var flow = EngineConnectFlow(state: .notConnected)
        flow.opened()
        flow.check(installed: true, loggedIn: false)
        #expect(flow.state == .waiting)
        flow.check(installed: true, loggedIn: true)
        #expect(flow.state == .connected)
    }

    @Test func leavingTheViewStopsWaiting() {
        var flow = EngineConnectFlow(state: .notConnected)
        flow.opened()
        flow.stopped()
        #expect(flow.state == .notConnected)
    }
}
