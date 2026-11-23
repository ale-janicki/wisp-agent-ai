import Foundation
import WispCore

struct MeetingEngineClient: Sendable {
    private static let assistTimeout: TimeInterval = 100
    private static let prepTimeout: TimeInterval = 260
    private static let agendaTimeout: TimeInterval = 20
    private static let probeTimeout: TimeInterval = 10
    private static let searchTimeout: TimeInterval = 15

    let wisp: URL
    let environment: [String: String]

    init(layout: RuntimeLayout) {
        wisp = layout.wisp
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("UV_") && $0.key != "PYTHONPATH" }
        environment["WISP_RESOURCES"] = layout.src.path
        environment["PATH"] = ClaudeLocator.effectivePATH
        self.environment = environment
    }

    var brainSearch: BrainSearchCLI {
        let wisp = wisp
        let environment = environment
        return BrainSearchCLI { arguments in
            guard case .success(let output) = CommandRunner.run(
                executable: wisp, arguments: arguments, environment: environment,
                timeout: arguments.contains("--help") ? Self.probeTimeout : Self.searchTimeout
            ) else { return nil }
            return output
        }
    }

    func assist(transcript: String, context: String, already: [String]) async throws -> [AssistItem] {
        let body = try JSONSerialization.data(withJSONObject: ["transcript": transcript, "context": context, "already": already])
        return AssistReport.parse(try await run(["reuniao", "assist"], stdin: body, timeout: Self.assistTimeout))
    }

    func prep(event: MeetingEvent?, description: String) async throws -> PrepReport {
        let payload: [String: Any] = [
            "titulo": event?.title ?? "", "notas": event?.notes ?? "", "participantes": event?.attendees ?? [], "descricao": description,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        return PrepReport.parse(try await run(["reuniao", "prep"], stdin: body, timeout: Self.prepTimeout))
    }

    func todayEvents() async -> [MeetingEvent] {
        guard let data = try? await run(["agenda", "eventos", "--hoje"], stdin: nil, timeout: Self.agendaTimeout) else { return [] }
        return MeetingEvent.parse(data)
    }

    private func run(_ arguments: [String], stdin: Data?, timeout: TimeInterval) async throws -> Data {
        let executable = wisp
        let environment = environment
        let token = CommandCancellation()
        let result = await withTaskCancellationHandler {
            await Task.detached {
                CommandRunner.run(
                    executable: executable, arguments: arguments, stdin: stdin, environment: environment, timeout: timeout,
                    cancellation: token
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
            if output.timedOut { throw NoteWriterError.failed("o motor passou de \(Int(timeout)) s") }
            guard output.status == 0 else {
                let reported = (try? JSONSerialization.jsonObject(with: output.stderr) as? [String: Any])?["erro"] as? String
                throw NoteWriterError.failed(reported ?? "o comando falhou (código \(output.status))")
            }
            return output.stdout
        }
    }
}
