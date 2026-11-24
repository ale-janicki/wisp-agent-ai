import Foundation
import WispCore

struct WispNoteWriter: MeetingNoteWriter {
    private static let timeout: TimeInterval = 1300

    let wisp: URL
    let environment: [String: String]

    init(layout: RuntimeLayout) {
        wisp = layout.wisp
        var environment = RuntimeEnvironment.forRuntime()
        environment["WISP_RESOURCES"] = layout.src.path
        environment["PATH"] = ClaudeLocator.effectivePATH
        self.environment = environment
    }

    func writeNote(folder: URL) async throws -> NoteOutcome {
        let executable = wisp
        let environment = environment
        let token = CommandCancellation()
        let result = await withTaskCancellationHandler {
            await Task.detached {
                CommandRunner.run(
                    executable: executable, arguments: ["reuniao", "nota", folder.path], environment: environment,
                    timeout: Self.timeout, cancellation: token
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
            if output.status == 3 { throw MeetingNoteBusy() }
            if output.timedOut { throw NoteWriterError.failed("o motor passou de \(Int(Self.timeout)) s") }
            guard output.status == 0, let report = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] else {
                let reported = (try? JSONSerialization.jsonObject(with: output.stderr) as? [String: Any])?["erro"] as? String
                throw NoteWriterError.failed(reported ?? "o comando de nota falhou (código \(output.status))")
            }
            return NoteOutcome(
                generated: report["gerada"] as? Bool ?? false, reason: report["motivo"] as? String, title: report["titulo"] as? String
            )
        }
    }
}

enum NoteWriterError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let reason): reason
        }
    }
}
