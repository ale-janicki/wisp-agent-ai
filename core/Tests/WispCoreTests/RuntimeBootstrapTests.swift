import XCTest
@testable import WispCore

final class RuntimeBootstrapTests: XCTestCase {
    private let layout = RuntimeLayout(
        bundle: URL(fileURLWithPath: "/Applications/Wisp.app"), home: URL(fileURLWithPath: "/Users/rita"))

    func testSameVersionSkips() {
        XCTAssertFalse(RuntimeBootstrap.needsInstall(bundledVersion: "1.0", installedVersion: "1.0"))
        XCTAssertTrue(RuntimeBootstrap.needsInstall(bundledVersion: "1.1", installedVersion: "1.0"))
    }

    func testInterruptedInstallRetries() {
        XCTAssertTrue(RuntimeBootstrap.needsInstall(bundledVersion: "1.0", installedVersion: nil))
    }

    func testNoBundledRuntimeNeverInstalls() {
        XCTAssertFalse(RuntimeBootstrap.needsInstall(bundledVersion: nil, installedVersion: nil))
    }

    func testLayoutPaths() {
        XCTAssertEqual(layout.root.path, "/Users/rita/.local/share/wisp/runtime")
        XCTAssertEqual(layout.src.path, "/Users/rita/.local/share/wisp/runtime/src")
        XCTAssertEqual(layout.venv.path, "/Users/rita/.local/share/wisp/runtime/venv")
        XCTAssertEqual(layout.wisp.path, "/Users/rita/.local/share/wisp/runtime/venv/bin/wisp")
        XCTAssertEqual(layout.versionFile.path, "/Users/rita/.local/share/wisp/runtime/VERSION")
        XCTAssertEqual(layout.bundled.path, "/Applications/Wisp.app/Contents/Resources/runtime")
    }

    func testUvArguments() {
        XCTAssertEqual(RuntimeBootstrap.uvArguments(layout),
                       ["sync", "--frozen", "--no-dev", "--all-packages", "--project", layout.src.path])
    }

    func testUvEnvironmentPointsAtTheLayoutEvenWithASpaceInHome() {
        let spaced = RuntimeLayout(bundle: URL(fileURLWithPath: "/Applications/Wisp.app"), home: URL(fileURLWithPath: "/Users/Maria Silva"))
        let env = RuntimeBootstrap.uvEnvironment(spaced)
        XCTAssertEqual(env["UV_PROJECT_ENVIRONMENT"], "/Users/Maria Silva/.local/share/wisp/runtime/venv")
        XCTAssertEqual(env["UV_PYTHON_INSTALL_DIR"], "/Users/Maria Silva/.local/share/wisp/runtime/python")
        XCTAssertEqual(env["UV_CACHE_DIR"], "/Users/Maria Silva/.local/share/wisp/runtime/cache")
        XCTAssertEqual(env["UV_PYTHON"], "3.13")
        XCTAssertEqual(env["WISP_RESOURCES"], spaced.src.path)
    }

    func testProcessEnvironmentKeepsTheBaseAndUvWins() {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/rita", "HTTPS_PROXY": "http://p", "SSL_CERT_FILE": "/c.pem", "UV_PYTHON": "3.9"]
        let env = RuntimeBootstrap.processEnvironment(layout, base: base)
        for key in ["PATH", "HOME", "HTTPS_PROXY", "SSL_CERT_FILE"] { XCTAssertEqual(env[key], base[key], key) }
        XCTAssertEqual(env["UV_PYTHON"], "3.13")
        XCTAssertEqual(env["UV_PROJECT_ENVIRONMENT"], layout.venv.path)
    }
}
