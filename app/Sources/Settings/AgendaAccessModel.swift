import Foundation
import Observation
import os
import WispCore

@MainActor @Observable
final class AgendaAccessModel {
    static let shared = AgendaAccessModel()

    enum State: Equatable {
        case unknown, granted, partial, needed, denied, unavailable
    }

    private(set) var state = State.unknown
    private(set) var busy = false

    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "agenda")

    nonisolated static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/wisp-agenda")
    }

    func refresh() {
        run(arguments: ["permissao"], timeout: 10)
    }

    func ask() {
        run(arguments: ["permissao", "--pedir"], timeout: 90)
    }

    private func run(arguments: [String], timeout: TimeInterval) {
        guard !busy else { return }
        busy = true
        let helper = Self.helperURL
        Task.detached {
            let result = CommandRunner.run(executable: helper, arguments: arguments, timeout: timeout)
            let parsed = Self.parse(result)
            await MainActor.run {
                self.busy = false
                self.state = parsed
                self.log.info("agenda access -> \(String(describing: parsed), privacy: .public)")
            }
        }
    }

    nonisolated static func parse(_ result: Result<CommandOutput, BlockCommandError>) -> State {
        guard case .success(let output) = result, output.status == 0,
              let report = (try? JSONSerialization.jsonObject(with: output.stdout)) as? [String: String] else { return .unavailable }
        let values = Set(report.values)
        if values == ["granted"] { return .granted }
        if values.contains("denied") || values.contains("restricted") || values.contains("writeOnly") {
            return values.contains("granted") ? .partial : .denied
        }
        return values.contains("granted") ? .partial : .needed
    }

    var sentence: String {
        switch state {
        case .unknown: "Verificando…"
        case .granted: "O Wisp pode ler e criar seus compromissos e lembretes."
        case .partial: "Só uma parte está liberada. Veja Ajustes do Sistema > Privacidade e Segurança > Calendários e Lembretes."
        case .needed: "Permita uma vez para o agente ver sua agenda e seus lembretes."
        case .denied: "Negado. Libere o Wisp em Ajustes do Sistema > Privacidade e Segurança > Calendários e Lembretes."
        case .unavailable: "Não consegui falar com o ajudante da agenda; atualize o Wisp."
        }
    }
}
