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

    @ObservationIgnored private var block: TelegramBlock?
    @ObservationIgnored private var checkedAt: Date?
    @ObservationIgnored private var readGeneration = 0

    private static let readTimeout: TimeInterval = 5
    static let actionTimeout: TimeInterval = 35
    private static let closeTimeout: TimeInterval = 300
    private static let statusMaxAge: TimeInterval = 30

    var isUp: Bool { link == .up }

    var loadedTopics: [TelegramTopic]? {
        if case .loaded(let list) = topics { return list }
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
                topics = .failed("\(BlockCommandName.of(block.list ?? "")) não tem saída JSON")
            }
        case .failure(let error):
            topics = .failed("Não consegui ler os tópicos: \(error.localizedDescription)")
        }
    }

    func ensureFreshStatus() async {
        guard let block, block.isComplete else { return }
        if let checkedAt, Date().timeIntervalSince(checkedAt) < Self.statusMaxAge { return }
        await checkStatus(block)
    }

    private func checkStatus(_ block: TelegramBlock) async {
        let result = await Self.run(block.status ?? "", timeout: Self.readTimeout)
        checkedAt = Date()
        switch result {
        case .success(let data):
            guard let status = try? TelegramTopics.parseStatus(data) else {
                link = .down("\(BlockCommandName.of(block.status ?? "")) não tem saída JSON")
                return
            }
            link = status.up ? .up : .down("o bot do Telegram não está lendo nesta máquina")
        case .failure(let error):
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
        case .failure(let error):
            return .failure(TelegramFailure("Não consegui criar o tópico: \(error.localizedDescription)"))
        }
    }

    func send(thread: Int, text: String) async -> TelegramFailure? {
        guard let command = block?.send else { return TelegramFailure("Telegram não configurado") }
        let filled = CommandTemplate.fill(command, ["thread": String(thread), "text": text])
        if case .failure(let error) = await Self.run(filled, timeout: Self.actionTimeout) {
            return TelegramFailure("Não consegui mandar ao Telegram: \(error.localizedDescription)")
        }
        return nil
    }

    func close(thread: Int) async {
        guard let command = block?.close, !closing.contains(thread) else { return }
        closing.insert(thread)
        actionError = nil
        let filled = CommandTemplate.fill(command, ["thread": String(thread)])
        let result = await Self.run(filled, timeout: Self.closeTimeout)
        closing.remove(thread)
        if case .failure(let error) = result {
            actionError = "Não consegui encerrar o tópico: \(error.localizedDescription)"
        }
        await refresh()
    }

    private nonisolated static func run(_ command: String, timeout: TimeInterval) async -> Result<Data, BlockCommandError> {
        await Task.detached { BlockCommand.run(command, timeout: timeout) }.value
    }
}

struct TelegramFailure: Error, Equatable {
    let sentence: String
    init(_ sentence: String) { self.sentence = sentence }
}
