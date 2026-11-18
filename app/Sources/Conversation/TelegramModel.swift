import Foundation
import Observation
import WispCore

@MainActor @Observable
final class TelegramModel {
    enum Link: Equatable {
        case notConfigured
        case checking
        case up
        case remote(String)
        case down(String)
    }

    enum Topics: Equatable {
        case loading
        case loaded([TelegramTopic])
        case failed(String)
    }

    private(set) var link: Link = .notConfigured
    private(set) var topics: Topics = .loading
    private(set) var closing: Set<Int> = []
    private(set) var actionError: String?
    private var closed: Set<Int> = []

    @ObservationIgnored private var block: TelegramBlock?
    @ObservationIgnored private var checkedAt: Date?
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var lastClaimNeed: TelegramClaimNeed = .none
    @ObservationIgnored private var statusGeneration = 0

    private static let readTimeout: TimeInterval = 5
    static let actionTimeout: TimeInterval = 35
    private static let closeTimeout: TimeInterval = 300
    private static let claimTimeout: TimeInterval = 75
    private static let statusMaxAge: TimeInterval = 30

    var canSend: Bool {
        switch link {
        case .up, .remote: true
        case .notConfigured, .checking, .down: false
        }
    }

    var downReason: String? {
        if case .down(let reason) = link { return reason }
        return nil
    }

    var claimNeed: TelegramClaimNeed {
        (block?.claim ?? "").isEmpty ? .none : lastClaimNeed
    }

    var claimFrom: String? {
        guard case .handOff(let host) = claimNeed else { return nil }
        return TelegramTopics.hostName(host)
    }

    var loadedTopics: [TelegramTopic]? {
        if case .loaded(let list) = topics { return list.filter { !closed.contains($0.thread) } }
        return nil
    }

    func configure(_ block: TelegramBlock?) {
        guard block != self.block else { return }
        self.block = block
        checkedAt = nil
        link = block?.isComplete == true ? .checking : .notConfigured
    }

    func refresh() async {
        guard let block, block.isComplete else { return }
        readGeneration += 1
        let current = readGeneration
        await checkStatus(block)
        let result = await Self.run(block.list ?? "", timeout: Self.readTimeout)
        guard current == readGeneration else { return }
        switch result {
        case .success(let data):
            if let list = try? TelegramTopics.parseTopics(data) {
                topics = .loaded(list)
            } else {
                keepOrFail("\(BlockCommandName.of(block.list ?? "")) não tem saída JSON")
            }
        case .failure(let error):
            keepOrFail("Não consegui ler os tópicos: \(error.localizedDescription)")
        }
    }

    private func keepOrFail(_ sentence: String) {
        if case .loaded = topics { return }
        topics = .failed(sentence)
    }

    func ensureFreshStatus() async {
        guard let block, block.isComplete else { return }
        if let checkedAt, Date().timeIntervalSince(checkedAt) < Self.statusMaxAge { return }
        await checkStatus(block)
    }

    /// The outbox asks the bot directly: a 30 s old answer would keep a held message waiting for nothing.
    func checkNow() async {
        guard let block, block.isComplete else { return }
        await checkStatus(block)
    }

    /// `refresh` and `checkNow` can overlap; only the newest read (or a claim after it) sets the link.
    private func checkStatus(_ block: TelegramBlock) async {
        statusGeneration += 1
        let current = statusGeneration
        let result = await Self.run(block.status ?? "", timeout: Self.readTimeout)
        guard current == statusGeneration else { return }
        checkedAt = Date()
        switch result {
        case .success(let data):
            guard let status = try? TelegramTopics.parseStatus(data) else {
                lastClaimNeed = .none
                link = .down("\(BlockCommandName.of(block.status ?? "")) não tem saída JSON")
                return
            }
            lastClaimNeed = status.claimNeed
            switch status.reading {
            case .here: link = .up
            case .elsewhere(let host): link = .remote(TelegramTopics.hostName(host))
            case .nobody: link = .down("nenhuma máquina está lendo o Telegram")
            }
        case .failure(let error):
            lastClaimNeed = .none
            link = .down(error.localizedDescription)
        }
    }

    // MARK: Actions (each returns the failure as one sentence, nil when done)

    func create(name: String, cwd: String) async -> Result<TelegramCreated, TelegramFailure> {
        guard let command = block?.create else { return .failure(TelegramFailure("Telegram não configurado")) }
        let filled = CommandTemplate.fill(command, ["name": name, "cwd": cwd])
        switch await Self.run(filled, timeout: Self.actionTimeout) {
        case .success(let data):
            guard let created = try? TelegramTopics.parseCreated(data) else {
                return .failure(TelegramFailure("o tópico não voltou em JSON"))
            }
            return .success(created)
        case .failure(.timedOut):
            return .failure(TelegramFailure("o tópico demorou demais e pode já existir; confira no Telegram antes de tentar de novo", retry: false))
        case .failure(let error):
            return .failure(TelegramFailure("Não consegui criar o tópico: \(error.localizedDescription)"))
        }
    }

    func claim(thread: Int?) async -> TelegramFailure? {
        guard let command = block?.claim, !command.isEmpty else { return nil }
        let filled = CommandTemplate.fill(command, ["thread": thread.map(String.init) ?? ""])
        switch await Self.run(filled, timeout: Self.claimTimeout) {
        case .success(let data):
            guard let claimed = try? TelegramTopics.parseClaim(data), claimed.ok else {
                return TelegramFailure("a troca de máquina não voltou em JSON; a mensagem não foi enviada")
            }
            statusGeneration += 1
            link = .up
            lastClaimNeed = .none
            checkedAt = Date()
            return nil
        case .failure(let error):
            return TelegramFailure(TelegramTopics.claimFailure(error.localizedDescription))
        }
    }

    /// `files` go through the profile's optional `{anexos}`; a profile without it can only send text.
    func send(thread: Int, text: String, files: [String] = []) async -> TelegramFailure? {
        guard let block, let command = block.send else { return TelegramFailure("Telegram não configurado", retry: false) }
        if !files.isEmpty, !block.sendsAttachments {
            return TelegramFailure("o perfil não sabe mandar anexos ao Telegram (falta {anexos} no send)", retry: false)
        }
        let filled = CommandTemplate.fill(command, ["thread": String(thread), "text": text],
                                          raw: ["anexos": CommandTemplate.repeated("--anexo", files)])
        switch await Self.run(filled, timeout: Self.actionTimeout) {
        case .success: return nil
        case .failure(.timedOut):
            return TelegramFailure("o envio demorou demais e pode já ter chegado; confira no Telegram antes de tentar de novo", retry: false)
        case .failure(let error):
            return TelegramFailure("Não consegui mandar ao Telegram: \(error.localizedDescription)")
        }
    }

    func close(thread: Int) async {
        guard let command = block?.close, !closing.contains(thread) else { return }
        closing.insert(thread)
        actionError = nil
        let filled = CommandTemplate.fill(command, ["thread": String(thread)])
        let result = await Self.run(filled, timeout: Self.closeTimeout)
        closing.remove(thread)
        switch result {
        case .success: closed.insert(thread)
        case .failure(let error): actionError = "Não consegui encerrar o tópico: \(error.localizedDescription)"
        }
        await refresh()
    }

    private nonisolated static func run(_ command: String, timeout: TimeInterval) async -> Result<Data, BlockCommandError> {
        await Task.detached { BlockCommand.run(command, timeout: timeout) }.value
    }
}

/// `retry` false: retrying blindly could duplicate (a timeout may have reached the bot) or can never work.
struct TelegramFailure: Error, Equatable {
    let sentence: String
    let retry: Bool
    init(_ sentence: String, retry: Bool = true) {
        self.sentence = sentence
        self.retry = retry
    }
}
