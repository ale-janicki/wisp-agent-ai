import Darwin
import Foundation
import Observation
import os
import WispCore

@MainActor @Observable
final class RuntimeInstaller {
    enum Phase: Equatable {
        case checking
        case installing(String)
        case ready(URL)
        case failed(String)
    }

    private enum Outcome: Sendable {
        case current, installed, failed(String)
    }

    private(set) var phase: Phase = .checking

    private let layout: RuntimeLayout
    private let log = Logger(subsystem: AppIdentity.bundleID, category: "runtime")
    private static let queue = DispatchQueue(label: "\(AppIdentity.bundleID).runtime-install", qos: .utility)

    init(bundle: URL = Bundle.main.bundleURL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        layout = RuntimeLayout(bundle: bundle, home: home)
    }

    /// Copies the bundled sources, runs `uv sync`, installs the shim, then writes VERSION last.
    /// One install at a time per machine: the work runs under a file lock on the runtime root.
    func ensure() async {
        phase = .checking
        let layout = layout
        let bundled = Self.readVersion(layout.bundled.appendingPathComponent("VERSION"))
        if bundled == nil, !FileManager.default.isExecutableFile(atPath: layout.wisp.path) {
            log.error("bundle has no runtime/VERSION and nothing is installed")
            phase = .failed("O Wisp não trouxe o ambiente de execução.")
            return
        }

        let base = ProcessInfo.processInfo.environment
        let outcome: Outcome = await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: Self.installIfNeeded(
                    layout: layout, bundled: bundled, base: base
                ) { label in
                    Task { @MainActor [weak self] in self?.phase = .installing(label) }
                })
            }
        }
        switch outcome {
        case .current:
            log.info("runtime atual")
            phase = .ready(layout.wisp)
        case .installed:
            log.info("runtime instalado")
            phase = .ready(layout.wisp)
        case .failed(let failure):
            log.error("runtime install failed: \(failure, privacy: .public)")
            phase = .failed(failure)
        }
    }

    /// Kills the install's child processes (uv, wisp), each of which leads its own process group.
    func cancel() {
        guard case .installing = phase else { return }
        var pids = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return }
        let children = pids.prefix(min(Int(count), pids.count)).filter { $0 > 0 }
        for pid in children { killpg(pid, SIGTERM) }
        usleep(300_000)
        for pid in children { killpg(pid, SIGKILL) }
    }

    nonisolated private static func installIfNeeded(
        layout: RuntimeLayout, bundled: String?, base: [String: String], progress: @Sendable (String) -> Void
    ) -> Outcome {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: layout.root, withIntermediateDirectories: true)
        } catch {
            return .failed("Não consegui preparar a pasta do Wisp: \(error.localizedDescription)")
        }
        let lock = open(layout.root.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { return .failed("Não consegui travar a instalação do Wisp.") }
        defer { close(lock) }
        if flock(lock, LOCK_EX | LOCK_NB) != 0 {
            progress("Outra janela do Wisp está instalando")
            guard flock(lock, LOCK_EX) == 0 else { return .failed("Não consegui travar a instalação do Wisp.") }
        }

        let installed = readVersion(layout.versionFile)
        let wispThere = fm.isExecutableFile(atPath: layout.wisp.path)
        let shim = layout.home.appendingPathComponent(".local/bin/wisp")
        let environment = runtimeEnvironment(layout, base: base)

        if let bundled, RuntimeBootstrap.needsInstall(bundledVersion: bundled, installedVersion: installed) || !wispThere {
            if let failure = fullInstall(layout: layout, version: bundled, environment: environment, progress: progress) {
                return .failed(failure)
            }
            restartBotIfLoaded()
            return .installed
        }
        if !fm.fileExists(atPath: shim.path) {
            progress("Instalando o comando wisp")
            if let failure = installShim(layout: layout, environment: environment) { return .failed(failure) }
            return .installed
        }
        return .current
    }

    nonisolated private static func runtimeEnvironment(_ layout: RuntimeLayout, base: [String: String]) -> [String: String] {
        let clean = base.filter { !$0.key.hasPrefix("UV_") && $0.key != "PYTHONPATH" }
        return RuntimeBootstrap.processEnvironment(layout, base: clean).merging(["UV_PYTHON_PREFERENCE": "only-managed"]) {
            _, pinned in pinned
        }
    }

    nonisolated private static func fullInstall(
        layout: RuntimeLayout, version: String, environment: [String: String], progress: @Sendable (String) -> Void
    ) -> String? {
        let fm = FileManager.default
        progress("Copiando os arquivos")
        do {
            try? fm.removeItem(at: layout.versionFile)
            try? fm.removeItem(at: layout.src)
            try fm.copyItem(at: layout.bundled.appendingPathComponent("src", isDirectory: true), to: layout.src)
        } catch {
            return "Não consegui copiar os arquivos do Wisp: \(error.localizedDescription)"
        }

        progress("Baixando o Python e as dependências")
        // A quarantined binary inside the bundle blocks on Gatekeeper when spawned; a copy without the flag runs.
        let uv = layout.root.appendingPathComponent("bin/uv")
        do {
            try fm.createDirectory(at: uv.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: uv)
            try fm.copyItem(at: layout.bundled.appendingPathComponent("bin/uv"), to: uv)
            if removexattr(uv.path, "com.apple.quarantine", 0) == -1 && errno != ENOATTR {
                return "Não consegui liberar o instalador do Wisp (erro \(errno))."
            }
        } catch {
            return "Não consegui preparar o instalador: \(error.localizedDescription)"
        }
        switch CommandRunner.run(
            executable: uv, arguments: RuntimeBootstrap.uvArguments(layout), environment: environment, timeout: 1200)
        {
        case .failure(let error):
            return "Não consegui rodar o instalador: \(error)"
        case .success(let output):
            if output.timedOut { return "A instalação demorou demais. Confira a internet e tente de novo." }
            if output.status != 0 {
                return lastLine(output.stderr) ?? "A instalação falhou (código \(output.status))."
            }
        }

        progress("Instalando o comando wisp")
        if let failure = installShim(layout: layout, environment: environment) { return failure }

        do {
            try Data((version + "\n").utf8).write(to: layout.versionFile, options: .atomic)
        } catch {
            return "Não consegui gravar a versão instalada: \(error.localizedDescription)"
        }
        return nil
    }

    /// The user's Telegram bot runs from this runtime: after an update it restarts so it runs the new code.
    nonisolated private static func restartBotIfLoaded() {
        let launchctl = URL(fileURLWithPath: "/bin/launchctl")
        let target = "gui/\(getuid())/\(AppIdentity.botLabel)"
        guard case .success(let probe) = CommandRunner.run(
            executable: launchctl, arguments: ["print", target], environment: [:], timeout: 10), probe.status == 0 else { return }
        _ = CommandRunner.run(executable: launchctl, arguments: ["kickstart", "-k", target], environment: [:], timeout: 30)
    }

    nonisolated private static func installShim(layout: RuntimeLayout, environment: [String: String]) -> String? {
        switch CommandRunner.run(
            executable: layout.wisp, arguments: ["setup", "shim", "--json"], environment: environment, timeout: 60)
        {
        case .failure(let error):
            return "Não consegui rodar o wisp: \(error)"
        case .success(let output):
            if output.timedOut { return "O comando wisp não respondeu." }
            if output.status != 0 {
                return shimSummary(output.stdout) ?? lastLine(output.stderr) ?? "Não consegui instalar o comando wisp."
            }
            return nil
        }
    }

    nonisolated private static func readVersion(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func lastLine(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    nonisolated private static func shimSummary(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["summary"] as? String
    }
}
