import Observation
import SwiftUI
import WispCore

// MARK: Hooks model

@MainActor @Observable
final class HooksModel {
    static let shared = HooksModel()

    enum State: Equatable {
        case loading
        case loaded(HooksReport)
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var toggling: String?
    private(set) var actionError: (id: String, message: String)?

    @ObservationIgnored private var generation = 0

    var report: HooksReport? {
        guard case .loaded(let report) = state else { return nil }
        return report
    }

    func refresh(block: HooksBlock) {
        guard let list = block.list else { return }
        generation += 1
        let current = generation
        Task { [weak self] in
            let state = await Task.detached(priority: .userInitiated) { Self.read(list: list) }.value
            guard let self, self.generation == current else { return }
            self.state = state
        }
    }

    func toggle(_ hook: HookEntry, block: HooksBlock) {
        guard toggling == nil, !hook.locked, let template = hook.enabled ? block.disable : block.enable else { return }
        toggling = hook.id
        actionError = nil
        let command = HookCommand.build(template, id: hook.id)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { BlockCommand.run(command) }.value
            guard let self else { return }
            if case .failure(let error) = result {
                let verb = hook.enabled ? "desligar" : "ligar"
                self.actionError = (hook.id, "Não consegui \(verb) \(hook.title): \(error.localizedDescription)")
            }
            self.toggling = nil
            self.refresh(block: block)
        }
    }

    nonisolated private static func read(list: String) -> State {
        switch BlockCommand.run(list) {
        case .failure(let error):
            return .failed("Não consegui listar os hooks: \(error.localizedDescription)")
        case .success(let data):
            do {
                return .loaded(try HooksReport.parse(data))
            } catch {
                return .failed("Não consegui ler os hooks: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: Commands model

@MainActor @Observable
final class CommandsModel {
    static let shared = CommandsModel()

    enum State: Equatable {
        case loading
        case loaded([CommandEntry])
    }

    private(set) var state: State = .loading

    func refresh(block: CommandsBlock) {
        let dirs = block.dirs ?? []
        Task { [weak self] in
            let entries = await Task.detached(priority: .userInitiated) { CommandScanner.scan(dirs: dirs) }.value
            self?.state = .loaded(entries)
        }
    }
}

// MARK: Hooks

struct HooksSection: View {
    let profile: Profile
    private let model = HooksModel.shared

    private var block: HooksBlock? { profile.blocks?.hooks }

    var body: some View {
        switch model.state {
        case .loading:
            SkeletonRows(count: 4)
        case .loaded(let report) where report.hooks.isEmpty:
            TabMessage(text: "Nenhum hook configurado")
        case .loaded(let report):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(report.groups) { group in
                    SectionCaption(text: group.title, inset: 0)
                    ForEach(Array(group.hooks.enumerated()), id: \.element.id) { index, hook in
                        if index > 0 { Divider().overlay(Theme.stroke) }
                        HookRow(
                            hook: hook,
                            canToggle: canToggle(hook),
                            busy: model.toggling == hook.id,
                            toggle: { if let block { model.toggle(hook, block: block) } }
                        )
                        if let error = model.actionError, error.id == hook.id {
                            InlineError(text: error.message)
                        }
                    }
                }
            }
        case .failed(let message):
            TabMessage(text: message)
        }
    }

    private func canToggle(_ hook: HookEntry) -> Bool {
        !hook.locked && (hook.enabled ? block?.disable : block?.enable) != nil
    }

    static func summary(_ report: HooksReport) -> String {
        let locked = report.hooks.filter(\.locked).count
        return locked == 0 ? "\(report.hooks.count)" : "\(report.hooks.count) · \(locked) \(locked == 1 ? "trava" : "travas")"
    }
}

private struct HookRow: View {
    let hook: HookEntry
    let canToggle: Bool
    let busy: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(hook.title)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(hook.enabled ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = hook.detail {
                    Text(detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if hook.missing {
                    Text("script ausente")
                        .font(Theme.Font.captionMono)
                        .foregroundStyle(Theme.busy)
                        .lineLimit(1)
                }
            }
            .help(hook.command)
            Spacer(minLength: Theme.Space.s)
            if hook.locked {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "lock.fill")
                    Text("trava")
                }
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
            } else if canToggle {
                ConfirmAction(
                    label: hook.enabled ? "Desligar" : "Ligar",
                    question: "\(hook.enabled ? "Desligar" : "Ligar") \(hook.title)?",
                    busy: busy,
                    action: toggle
                )
            }
        }
        .padding(.vertical, Theme.Space.s)
        .frame(minHeight: Theme.Layout.rowHeight)
    }
}

// MARK: Commands

struct CommandsSection: View {
    private let model = CommandsModel.shared

    var body: some View {
        switch model.state {
        case .loading:
            SkeletonRows(count: 2)
        case .loaded(let entries) where entries.isEmpty:
            TabMessage(text: "Nenhum comando encontrado")
        case .loaded(let entries):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().overlay(Theme.stroke) }
                    CommandRow(entry: entry)
                }
            }
        }
    }
}

private struct CommandRow: View {
    let entry: CommandEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let detail = entry.detail {
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .help(entry.path)
        .frame(maxWidth: .infinity, minHeight: Theme.Layout.rowHeight, alignment: .leading)
        .padding(.vertical, Theme.Space.s)
    }
}

extension Profile {
    var hasHooks: Bool { !(blocks?.hooks?.list?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
    var hasCommands: Bool { !(blocks?.commands?.dirs ?? []).isEmpty }
}
