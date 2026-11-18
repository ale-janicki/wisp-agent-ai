#if DEBUG
import AppKit
import Foundation
import WispCore

/// `-WispSetupHome <dir> -WispSetupAutorun`: walks the wizard against a fake HOME and snapshots every step into
/// `<dir>/snapshots`. Without `-WispSetupAutorun` the window just opens on the fake HOME for manual use.
@MainActor
enum SetupAutorun {
    static func homeOverride(from arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "-WispSetupHome"), arguments.indices.contains(index + 1) else { return nil }
        let url = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
        let real = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard url.path != real.path, !real.path.hasPrefix(url.path + "/") else {
            print("setup-autorun: refusing a HOME that is, or contains, the real home")
            return nil
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func isRequested(_ arguments: [String]) -> Bool { arguments.contains("-WispSetupAutorun") }

    static func run(controller: SetupWindowController, home: URL) async {
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)

        var waited = 0
        while controller.session.model == nil, waited < 600 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard let model = controller.session.model else {
            print("setup-autorun: the runtime never became ready (\(controller.session.runtime.phase))")
            NSApp.terminate(nil)
            return
        }
        try? await Task.sleep(for: .seconds(1))
        model.current = .system
        await snapshot(controller, "1-system", snapshots)

        model.detailsOpen = true
        await model.run(.system)
        report(model, .system)
        await snapshot(controller, "2-system-done", snapshots)
        model.advance()

        await snapshot(controller, "3-login", snapshots)
        model.skip(.login)
        model.advance()

        await model.run(.brain)
        report(model, .brain)
        await snapshot(controller, "4-brain", snapshots)
        model.advance()

        await model.run(.harness)
        report(model, .harness)
        await snapshot(controller, "5-harness", snapshots)
        model.advance()

        model.detailsOpen = false
        await model.run(.telegram, arguments: ["--skip"])
        report(model, .telegram)
        await snapshot(controller, "6-telegram", snapshots)
        model.advance()

        model.skip(.spotify)
        report(model, .spotify)
        await snapshot(controller, "7-spotify", snapshots)
        model.advance()

        model.profileName = "Wisp"
        model.profileUserName = "Teste"
        model.profileAvatar = nil
        await snapshot(controller, "8-profile-form", snapshots)
        model.detailsOpen = true
        await model.run(.profile, arguments: ["--name", "Wisp", "--user-name", "Teste"])
        report(model, .profile)
        await snapshot(controller, "9-profile", snapshots)
        model.advance()

        await snapshot(controller, "10-done", snapshots)
        print("setup-autorun: finished")
        NSApp.terminate(nil)
    }

    private static func report(_ model: SetupModel, _ step: SetupStepID) {
        let row = model.row(step)
        print("setup-autorun: \(step.rawValue) state=\(row.state)")
        for detail in row.report?.details ?? [] {
            print("setup-autorun:   $ \(detail.command) -> exit \(detail.exit)")
        }
    }

    private static func snapshot(_ controller: SetupWindowController, _ name: String, _ directory: URL) async {
        try? await Task.sleep(for: .milliseconds(700))
        guard let view = controller.window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            print("setup-autorun: snapshot \(url.path)")
        } catch {
            print("setup-autorun: snapshot failed \(name): \(error.localizedDescription)")
        }
    }
}
#endif
