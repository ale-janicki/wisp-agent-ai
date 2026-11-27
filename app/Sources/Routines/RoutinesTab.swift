import SwiftUI
import WispCore

struct RoutinesSection: View {
    let profile: Profile
    @State private var logJob: RoutineJob?
    @State private var logIndex = 0
    @State private var debugLogLabel: String? = Self.initialLogLabel
    private let routines = RoutinesModel.shared

    private var block: RoutinesBlock? { profile.blocks?.routines }

    #if DEBUG
    static var snapshotLogLabel: String?
    #endif

    private static var initialLogLabel: String? {
        #if DEBUG
        return snapshotLogLabel
        #else
        return nil
        #endif
    }

    var body: some View {
        Group {
            if let logJob {
                LogPane(job: logJob, index: $logIndex, log: routines.log, load: routines.loadLog) {
                    self.logJob = nil
                }
            } else {
                list
            }
        }
        .onAppear(perform: openDebugLog)
        .onChange(of: routines.state, openDebugLog)
    }

    @ViewBuilder
    private var list: some View {
        switch routines.state {
        case .loading:
            SkeletonRows(count: 6)
        case .loaded(let rows) where rows.isEmpty:
            TabMessage(text: "Nenhuma rotina encontrada")
        case .loaded(let rows):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().overlay(Theme.stroke) }
                    RoutineRow(
                        row: row,
                        canToggle: canToggle(row),
                        busy: routines.toggling == row.id,
                        toggle: { if let block { routines.toggle(row, block: block) } },
                        showLog: {
                            logIndex = 0
                            logJob = row.job
                        }
                    )
                    if let error = routines.actionError, error.label == row.id {
                        InlineError(text: error.message)
                    }
                }
            }
        case .failed(let message):
            TabMessage(text: message)
        }
    }

    private func openDebugLog() {
        guard let label = debugLogLabel, case .loaded(let rows) = routines.state,
              let row = rows.first(where: { $0.id == label }) else { return }
        debugLogLabel = nil
        logJob = row.job
    }

    private func canToggle(_ row: RoutinesModel.Row) -> Bool {
        guard row.job.installed, let status = try? row.status.get() else { return false }
        return (status.isLoaded ? block?.stop : block?.start) != nil
    }
}

private struct RoutineRow: View {
    let row: RoutinesModel.Row
    let canToggle: Bool
    let busy: Bool
    let toggle: () -> Void
    let showLog: () -> Void

    private var status: RoutineStatus? { try? row.status.get() }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            dot
            VStack(alignment: .leading, spacing: 2) {
                Text(row.job.name)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(status?.isLoaded == false ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(1)
                if let description = row.job.description {
                    Text(description)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(row.summary)
                    .font(Theme.Font.captionMono)
                    .foregroundStyle(summaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(row.job.label)
            Spacer(minLength: Theme.Space.s)
            if !row.job.logs.isEmpty {
                Button("Log", action: showLog)
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost, size: .compact))
            }
            if canToggle, let status {
                ConfirmAction(
                    label: status.isLoaded ? "Desligar" : "Ligar",
                    question: "\(status.isLoaded ? "Desligar" : "Ligar") \(row.job.name)?",
                    busy: busy,
                    action: toggle
                )
            }
        }
        .padding(.vertical, Theme.Space.s)
        .frame(minHeight: Theme.Layout.rowHeight)
    }

    @ViewBuilder
    private var dot: some View {
        switch row.job.installed ? status?.state : nil {
        case .unloaded:
            Circle().strokeBorder(Theme.textTertiary, lineWidth: 1.5).frame(width: 8, height: 8)
        default:
            Circle().fill(dotColor).frame(width: 8, height: 8)
        }
    }

    private var dotColor: Color {
        guard row.job.installed, let status else { return Theme.error }
        switch status.state {
        case .running: return Theme.ok
        case .waiting, .other: return status.lastRunFailed ? Theme.error : Theme.textSecondary
        case .unloaded: return Theme.textTertiary
        }
    }

    private var summaryColor: Color {
        guard row.job.installed, let status else { return Theme.error }
        if status.state != .running, status.lastRunFailed { return Theme.error }
        return Theme.textTertiary
    }
}

private struct LogPane: View {
    let job: RoutineJob
    @Binding var index: Int
    let log: RoutinesModel.LogState
    let load: (String) -> Void
    let close: () -> Void

    private var path: String { job.logs[min(index, job.logs.count - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Button(action: close) { Image(systemName: "chevron.left") }
                    .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                    .help("Voltar às rotinas")
                if job.logs.count > 1 {
                    ForEach(job.logs.indices, id: \.self) { i in
                        Button((job.logs[i] as NSString).lastPathComponent) { index = i }
                            .buttonStyle(CapsuleButtonStyle(kind: (i == index) ? .accent : .ghost, size: .compact))
                    }
                }
                Text(path)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button { load(path) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                    .help("Ler de novo")
            }
            content
        }
        .task(id: path) { load(path) }
    }

    @ViewBuilder
    private var content: some View {
        switch log {
        case .loading:
            SkeletonRows(count: 5)
        case .loaded(let lines) where lines.isEmpty:
            TabMessage(text: "Log vazio")
        case .loaded(let lines):
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(Theme.Font.tool)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.s)
            }
            .frame(maxHeight: 360)
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.hidden)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        case .failed(let message):
            TabMessage(text: message)
        }
    }
}
