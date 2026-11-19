import Foundation
import Observation
import WispCore

@MainActor @Observable
final class TelegramModel {
    enum Link: Equatable {
        case notConfigured
        case checking
        case up
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
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var topicsReadAt: Date?

    private static let readTimeout: TimeInterval = 5
    static let actionTimeout: TimeInterval = 35
    private static let closeTimeout: TimeInterval = 300

    var canShare: Bool { block?.canShare == true }
    var canPost: Bool { block?.canPost == true }
    var wispBinary: String? { block?.binary }

    var loadedTopics: [TelegramTopic]? {
        if case .loaded(let list) = topics { return list.filter { !closed.contains($0.thread) } }
        return nil
    }

    func configure(_ block: TelegramBlock?) {
        let block = block?.derivingActions()
        guard block != self.block else { return }
        self.block = block
        link = block?.isComplete == true ? .checking : .notConfigured
    }

    func refresh() async {
        guard let block, block.isComplete else { return }
        readGeneration += 1
        let current = readGeneration
        await checkStatus(block)
        await readTopics(block, generation: current)
    }

    func refreshTopicsIfStale(maxAge: TimeInterval = 30) async {
        guard let block, block.isComplete else { return }
        if let topicsReadAt, Date().timeIntervalSince(topicsReadAt) < maxAge { return }
        readGeneration += 1
        await readTopics(block, generation: readGeneration)
    }

    private func readTopics(_ block: TelegramBlock, generation current: Int) async {
        let result = await Self.run(block.list ?? "", timeout: Self.readTimeout)
        guard current == readGeneration else { return }
        switch result {
        case .success(let data):
            if let list = try? TelegramTopics.parseTopics(data) {
                topics = .loaded(list)
                topicsReadAt = Date()
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

    private func checkStatus(_ block: TelegramBlock) async {
        let result = await Self.run(block.status ?? "", timeout: Self.readTimeout)
        switch result {
        case .success(let data):
            guard let status = try? TelegramTopics.parseStatus(data) else {
                link = .down("\(BlockCommandName.of(block.status ?? "")) não tem saída JSON")
                return
            }
            link = status.up ? .up : .down("o bot do Telegram não está rodando")
        case .failure(let error):
            link = .down(error.localizedDescription)
        }
    }

    // MARK: Actions (each returns the failure as one sentence, nil when done)

    func share(session: String, cwd: String, name: String) async -> Result<TelegramShared, TelegramFailure> {
        guard let command = block?.share, !command.isEmpty else { return .failure(TelegramFailure("o perfil não sabe compartilhar no Telegram", retry: false)) }
        let filled = CommandTemplate.fill(command, ["session": session, "cwd": cwd, "name": name])
        switch await Self.run(filled, timeout: Self.actionTimeout) {
        case .success(let data):
            guard let shared = try? TelegramTopics.parseShared(data) else {
                return .failure(TelegramFailure("o tópico não voltou em JSON; confira no Telegram antes de tentar de novo", retry: false))
            }
            return .success(shared)
        case .failure(.timedOut):
            return .failure(TelegramFailure("o tópico demorou demais e pode já existir; confira no Telegram antes de tentar de novo", retry: false))
        case .failure(let error):
            return .failure(TelegramFailure("Não consegui compartilhar no Telegram: \(error.localizedDescription)"))
        }
    }

    func post(_ turn: TelegramPost) async -> TelegramFailure? {
        guard let command = block?.post, !command.isEmpty else { return TelegramFailure("o perfil não sabe espelhar no Telegram", retry: false) }
        switch await Self.run(command, stdin: turn.payload, timeout: Self.actionTimeout) {
        case .success: return nil
        case .failure(.timedOut):
            return TelegramFailure("o espelho no Telegram demorou demais e pode já ter chegado", retry: false)
        case .failure(let error):
            return TelegramFailure("Não consegui espelhar no Telegram: \(error.localizedDescription)")
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

    private nonisolated static func run(_ command: String, stdin: Data? = nil, timeout: TimeInterval) async -> Result<Data, BlockCommandError> {
        await Task.detached { BlockCommand.run(command, stdin: stdin, timeout: timeout) }.value
    }
}

struct TelegramFailure: Error, Equatable {
    let sentence: String
    let retry: Bool
    init(_ sentence: String, retry: Bool = true) {
        self.sentence = sentence
        self.retry = retry
    }
}
