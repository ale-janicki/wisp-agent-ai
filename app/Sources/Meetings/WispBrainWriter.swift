import Foundation
import WispCore

struct WispBrainWriter: MeetingBrainWriter {
    private static let timeout: TimeInterval = 60

    let wisp: URL
    let environment: [String: String]
    let brain: String

    init(layout: RuntimeLayout, brain: String) {
        wisp = layout.wisp
        self.brain = brain
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("UV_") && $0.key != "PYTHONPATH" }
        environment["WISP_RESOURCES"] = layout.src.path
        if let path = ClaudeLocator.cachedLoginShellPATH { environment["PATH"] = path }
        self.environment = environment
    }

    func syncNote(folder: URL) async throws -> URL {
        let executable = wisp
        let environment = environment
        let arguments = ["reuniao", "brain", folder.path, "--brain", brain]
        let token = CommandCancellation()
        let result = await withTaskCancellationHandler {
            await Task.detached {
                CommandRunner.run(
                    executable: executable, arguments: arguments, environment: environment, timeout: Self.timeout, cancellation: token
                )
            }.value
        } onCancel: {
            token.cancel()
        }
        if Task.isCancelled { throw CancellationError() }
        switch result {
        case .failure(let error):
            throw NoteWriterError.failed(error.localizedDescription)
        case .success(let output):
            if output.status == -2 { throw CancellationError() }
            if output.timedOut { throw NoteWriterError.failed("o comando do brain passou de \(Int(Self.timeout)) s") }
            guard output.status == 0, let report = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
                  let path = report["nota"] as? String else {
                let reported = (try? JSONSerialization.jsonObject(with: output.stderr) as? [String: Any])?["erro"] as? String
                throw NoteWriterError.failed(reported ?? "o comando do brain falhou (código \(output.status))")
            }
            return URL(fileURLWithPath: path)
        }
    }
}
