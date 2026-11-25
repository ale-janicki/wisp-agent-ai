import XCTest
@testable import WispCore

final class PaneModeDeciderTests: XCTestCase {
    func testTheAlternateScreenShowsTheGrid() {
        XCTAssertEqual(PaneModeDecider.decide(altScreen: true), .grid(.alternateScreen))
        XCTAssertTrue(PaneModeDecider.decide(altScreen: true).isGrid)
    }

    func testAPlainPromptShowsTheBlocks() {
        XCTAssertEqual(PaneModeDecider.decide(altScreen: false), .blocks)
        XCTAssertEqual(PaneModeDecider.decide(altScreen: false, mouse: false, command: "ls -G", allowlist: ["claude"]), .blocks)
    }

    func testMouseTrackingAndTheAllowlistShowTheGrid() {
        XCTAssertEqual(PaneModeDecider.decide(altScreen: false, mouse: true), .grid(.mouseTracking))
        XCTAssertEqual(PaneModeDecider.decide(altScreen: false, command: "  claude --resume", allowlist: ["claude"]), .grid(.allowlisted))
        XCTAssertEqual(PaneModeDecider.decide(altScreen: false, command: "/usr/local/bin/ssh host", allowlist: ["ssh"]), .grid(.allowlisted))
        XCTAssertEqual(PaneModeDecider.decide(altScreen: false, command: "echo claude", allowlist: ["claude"]), .blocks)
    }

    func testTheAlternateScreenWinsOverTheRest() {
        XCTAssertEqual(PaneModeDecider.decide(altScreen: true, mouse: true, command: "claude", allowlist: ["claude"]), .grid(.alternateScreen))
    }

    private func mode(_ command: String) -> PaneMode {
        PaneModeDecider.decide(altScreen: false, command: command, allowlist: PaneModeDecider.defaultAllowlist)
    }

    func testEnvAssignmentsAndWrappersAreSkipped() {
        XCTAssertEqual(mode("FOO=1 claude"), .grid(.allowlisted))
        XCTAssertEqual(mode("A=1 B=\"x\" claude --resume"), .grid(.allowlisted))
        XCTAssertEqual(mode("sudo htop"), .grid(.allowlisted))
        XCTAssertEqual(mode("sudo -E FOO=1 exec vim file"), .grid(.allowlisted))
        XCTAssertEqual(mode("command klaus"), .grid(.allowlisted))
        XCTAssertEqual(mode("sudo"), .blocks)
        XCTAssertEqual(mode("FOO=1"), .blocks)
        XCTAssertEqual(mode("echo claude"), .blocks)
    }

    func testTheDefaultAllowlistPrograms() {
        for name in ["claude", "klaus", "ssh host", "mosh host", "tmux", "top", "htop", "btop", "less f", "more f", "man ls", "nano f", "vim f", "nvim", "vi", "emacs"] {
            XCTAssertEqual(mode(name), .grid(.allowlisted), name)
        }
        XCTAssertEqual(mode("ls"), .blocks)
    }

    func testReplsGetTheGridButScriptsDoNot() {
        XCTAssertEqual(mode("python3"), .grid(.allowlisted))
        XCTAssertEqual(mode("python"), .grid(.allowlisted))
        XCTAssertEqual(mode("node"), .grid(.allowlisted))
        XCTAssertEqual(mode("irb"), .grid(.allowlisted))
        XCTAssertEqual(mode("python3 -i"), .grid(.allowlisted))
        XCTAssertEqual(mode("python3 script.py"), .blocks)
        XCTAssertEqual(mode("node app.js"), .blocks)
        XCTAssertEqual(mode("python3 -c 'print(1)'"), .blocks)
        XCTAssertEqual(mode("python3 -m http.server"), .blocks)
        XCTAssertEqual(mode("node --version"), .blocks)
    }

    func testDockerAndKubectlOnlyWhenInteractive() {
        XCTAssertEqual(mode("docker run -it alpine sh"), .grid(.allowlisted))
        XCTAssertEqual(mode("docker exec -it web bash"), .grid(.allowlisted))
        XCTAssertEqual(mode("docker run --rm -i -t alpine"), .grid(.allowlisted))
        XCTAssertEqual(mode("kubectl exec -it pod -- sh"), .grid(.allowlisted))
        XCTAssertEqual(mode("docker ps"), .blocks)
        XCTAssertEqual(mode("docker run alpine echo hi"), .blocks)
        XCTAssertEqual(mode("docker exec web ls"), .blocks)
        XCTAssertEqual(mode("docker logs -f web"), .blocks)
        XCTAssertEqual(mode("kubectl get pods"), .blocks)
        XCTAssertEqual(mode("kubectl exec pod -- ls"), .blocks)
    }

    func testAnyInteractiveSegmentOfTheLineTakesTheGrid() {
        XCTAssertEqual(mode("cd x && claude"), .grid(.allowlisted))
        XCTAssertEqual(mode("nvm use && node"), .grid(.allowlisted))
        XCTAssertEqual(mode("false || vim a; echo done"), .grid(.allowlisted))
        XCTAssertEqual(mode("ls | claude"), .grid(.allowlisted))
        XCTAssertEqual(mode("cd x && ls"), .blocks)
        XCTAssertEqual(mode("echo 'a && claude'"), .blocks)
        XCTAssertEqual(mode("echo a\\;claude"), .blocks)
    }

    func testAPipedProgramHasNoScreen() {
        XCTAssertEqual(mode("claude -p x | jq"), .blocks)
        XCTAssertEqual(mode("cd x && claude -p x | jq ."), .blocks)
        XCTAssertEqual(mode("claude -p x || echo no"), .grid(.allowlisted))
    }

    func testSshWithARemoteCommandStaysInBlocks() {
        XCTAssertEqual(mode("ssh host"), .grid(.allowlisted))
        XCTAssertEqual(mode("ssh -p 22 -i key user@host"), .grid(.allowlisted))
        XCTAssertEqual(mode("ssh -t host"), .grid(.allowlisted))
        XCTAssertEqual(mode("ssh host uptime"), .blocks)
        XCTAssertEqual(mode("ssh -p 22 host ls -l"), .blocks)
        XCTAssertEqual(mode("ssh -o StrictHostKeyChecking=no host 'uptime'"), .blocks)
    }

    func testTmuxOnlyAttachNewOrNothingTakesTheGrid() {
        XCTAssertEqual(mode("tmux"), .grid(.allowlisted))
        XCTAssertEqual(mode("tmux attach"), .grid(.allowlisted))
        XCTAssertEqual(mode("tmux -L work a -t main"), .grid(.allowlisted))
        XCTAssertEqual(mode("tmux new -s dev"), .grid(.allowlisted))
        XCTAssertEqual(mode("tmux new -d -s dev"), .blocks)
        XCTAssertEqual(mode("tmux ls"), .blocks)
        XCTAssertEqual(mode("tmux list-sessions"), .blocks)
        XCTAssertEqual(mode("tmux kill-session -t x"), .blocks)
        XCTAssertEqual(mode("tmux has-session -t x"), .blocks)
        XCTAssertEqual(mode("tmux display-message -p '#S'"), .blocks)
    }

    func testTopLoggingAndManLookupsStayInBlocks() {
        XCTAssertEqual(mode("top"), .grid(.allowlisted))
        XCTAssertEqual(mode("top -o cpu"), .grid(.allowlisted))
        XCTAssertEqual(mode("top -l 1"), .blocks)
        XCTAssertEqual(mode("man ls"), .grid(.allowlisted))
        XCTAssertEqual(mode("man -k copy"), .blocks)
        XCTAssertEqual(mode("man -f ls"), .blocks)
        XCTAssertEqual(mode("man -w ls"), .blocks)
    }

    func testMouseTrackingAloneIsTheGridWithAnEmptyAllowlist() {
        XCTAssertEqual(PaneModeDecider.decide(altScreen: false, mouse: true, command: "ls"), .grid(.mouseTracking))
    }
}
