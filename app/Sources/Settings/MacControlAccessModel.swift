import AppKit
import ApplicationServices
import Foundation
import Observation
import os
import WispCore

@MainActor @Observable
final class MacControlAccessModel {
    static let shared = MacControlAccessModel()

    enum Access: Equatable {
        case unknown, granted, needed, denied
    }

    private(set) var accessibility = Access.unknown
    private(set) var automation = Access.unknown
    private(set) var busy = false
    private(set) var appTrusted = false

    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "mac-control")

    nonisolated static let systemEvents = "com.apple.systemevents"
    nonisolated static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    nonisolated static let automationPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

    nonisolated static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/wisp-mac")
    }

    var granted: Bool { accessibility == .granted && automation == .granted }

    var helperNeedsItsOwnGrant: Bool { appTrusted && accessibility == .needed }

    func refresh() {
        appTrusted = AXIsProcessTrusted()
        if accessibility == .unknown { accessibility = appTrusted ? .granted : .needed }
        guard !busy else { return }
        Task.detached {
            let helper = Self.helperAccessibility()
            let status = Self.determineAutomation(ask: false)
            await MainActor.run {
                if let helper { self.accessibility = helper }
                self.automation = status
            }
        }
    }

    func ask() {
        guard !busy else { return }
        if !appTrusted {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            NSWorkspace.shared.open(URL(string: Self.accessibilityPane)!)
            refresh()
            return
        }
        if accessibility != .granted {
            NSWorkspace.shared.activateFileViewerSelecting([Self.helperURL])
            NSWorkspace.shared.open(URL(string: Self.accessibilityPane)!)
            refresh()
            return
        }
        busy = true
        Task.detached {
            Self.launchSystemEvents()
            let status = Self.determineAutomation(ask: true)
            await MainActor.run {
                self.busy = false
                self.automation = status
                if status != .granted { NSWorkspace.shared.open(URL(string: Self.automationPane)!) }
                self.log.info("mac control -> accessibility granted, automation \(String(describing: status), privacy: .public)")
            }
        }
    }

    nonisolated private static func helperAccessibility() -> Access? {
        let result = CommandRunner.run(executable: helperURL, arguments: ["permissao"], timeout: 10)
        guard case .success(let output) = result, output.status == 0,
              let report = (try? JSONSerialization.jsonObject(with: output.stdout)) as? [String: String],
              let state = report["acessibilidade"] else { return nil }
        return state == "granted" ? .granted : .needed
    }

    nonisolated private static func launchSystemEvents() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: systemEvents).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: systemEvents) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }

    nonisolated private static func determineAutomation(ask: Bool) -> Access {
        let target = NSAppleEventDescriptor(bundleIdentifier: systemEvents)
        guard let address = target.aeDesc else { return .needed }
        let status = AEDeterminePermissionToAutomateTarget(address, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch Int(status) {
        case Int(noErr): return .granted
        case errAEEventNotPermitted: return .denied
        default: return .needed
        }
    }

    var sentence: String {
        switch (accessibility, automation) {
        case (.granted, .granted): "O Wisp pode ler e clicar nas janelas e controlar apps do Mac quando você pedir."
        case (.needed, _) where appTrusted: "O Wisp está permitido, mas o ajudante wisp-mac ainda não: em Ajustes do Sistema > Privacidade e Segurança > Acessibilidade, clique em + e adicione o arquivo que o Finder vai mostrar (Wisp.app/Contents/Helpers/wisp-mac)."
        case (.needed, _), (.unknown, _): "Falta a Acessibilidade: é ela que deixa o Wisp ler a tela e clicar, digitar e usar atalhos em qualquer app."
        case (_, .denied): "Negado. Libere o Wisp em Ajustes do Sistema > Privacidade e Segurança > Automação."
        default: "Falta a Automação: é ela que deixa o Wisp controlar apps como Música, Safari e Mail por script."
        }
    }

    var accessibilityLine: String {
        switch accessibility {
        case .granted: "Acessibilidade do ajudante: permitida"
        case .unknown: "Acessibilidade: verificando…"
        default: helperNeedsItsOwnGrant ? "Acessibilidade do ajudante: falta adicionar" : "Acessibilidade: falta permitir"
        }
    }

    var automationLine: String {
        switch automation {
        case .granted: "Automação: permitida"
        case .unknown: "Automação: verificando…"
        case .denied: "Automação: negada"
        case .needed: "Automação: falta permitir"
        }
    }

    var buttonTitle: String {
        if busy { return "Aguardando resposta…" }
        if helperNeedsItsOwnGrant { return "Mostrar o ajudante" }
        return accessibility == .granted ? (automation == .denied ? "Abrir Ajustes do Sistema" : "Permitir Automação") : "Permitir Acessibilidade"
    }
}
