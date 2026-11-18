import SwiftUI
import WispCore

private enum Row: Identifiable {
    case message(ConversationMessage)
    case tools([ConversationMessage])

    var id: UUID {
        switch self {
        case .message(let message): message.id
        case .tools(let group): group[0].id
        }
    }
}

struct ConversationView: View {
    var model: ConversationViewModel

    private var rows: [Row] {
        var rows: [Row] = []
        for message in model.state.messages {
            if message.role == .tool, case .tools(let group)? = rows.last {
                rows[rows.count - 1] = .tools(group + [message])
            } else if message.role == .tool {
                rows.append(.tools([message]))
            } else {
                rows.append(.message(message))
            }
        }
        return rows
    }

    private var isEmpty: Bool {
        model.state.messages.isEmpty && !model.isThinking && !model.isFailed && !model.isLoadingHistory
    }

    var body: some View {
        if isEmpty {
            Text("Pergunte qualquer coisa ao \(model.personaName)")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                let bubbleWidth = max(160, (geo.size.width - 2 * Theme.Space.l) * 0.8)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.isLoadingHistory { HistorySkeleton() }
                            ForEach(rows) { row in
                                switch row {
                                case .message(let message):
                                    MessageRow(message: message, maxWidth: bubbleWidth)
                                    if let mark = model.heldMark(message) {
                                        HeldMarkRow(mark: mark, retry: { model.retryHeld(message) }, discard: { model.discardHeld(message) })
                                    }
                                case .tools(let group): ToolsRow(messages: group)
                                }
                            }
                            if let request = model.state.approvals.first {
                                ApprovalCard(request: request, queued: model.state.approvals.count - 1) { model.answer(request, $0) }
                                    .id(request.id)
                            } else if model.isThinking {
                                TypingRow(name: model.personaName)
                            }
                            if case .failed(let reason) = model.state.phase {
                                FailureRow(reason: reason) { model.retry() }
                            }
                            if case .held(let reason) = model.state.phase { HeldRow(reason: reason) }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.m)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottom)
                    }
                    .scrollIndicators(.hidden)
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: model.state) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: model.isLoadingHistory) { _, _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct MessageRow: View {
    let message: ConversationMessage
    let maxWidth: CGFloat
    var lineLimit: Int?

    var body: some View {
        switch message.role {
        case .user:
            HStack(spacing: 0) {
                Spacer(minLength: Theme.Space.xl * 2)
                userContent
                    .frame(maxWidth: maxWidth, alignment: .trailing)
            }
        case .assistant:
            HStack(spacing: 0) {
                bubble(Text(Self.markdown(message.text)), fill: Theme.surfaceHi)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                Spacer(minLength: Theme.Space.xl * 2)
            }
        case .system, .tool:
            Text(message.text)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.xs)
        }
    }

    /// A prompt with the attachment block shows its photos and files (never the paths); a preview stays one line.
    @ViewBuilder
    private var userContent: some View {
        if let attachments = MessageAttachments.parse(message.text) ?? MessageAttachments.unparsed(message.text) {
            if lineLimit != nil || attachments.items.isEmpty {
                bubble(Text(attachments.summary), fill: Theme.userBubble)
            } else {
                VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                    AttachmentStack(attachments: attachments, time: message.time, maxWidth: maxWidth * Self.imageShare)
                    if let caption = attachments.caption { bubble(Text(caption), fill: Theme.userBubble) }
                }
            }
        } else {
            bubble(Text(message.text), fill: Theme.userBubble)
        }
    }

    /// Images take ~70% of the column; `maxWidth` is already 80% of it.
    private static let imageShare: CGFloat = 0.875

    private func bubble(_ text: Text, fill: Color) -> some View {
        text
            .font(Theme.Font.body)
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.accentText)
            .lineSpacing(2)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 9)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var parsed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        let unsafe = parsed.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link else { return nil }
            return ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? nil : run.range
        }
        for range in unsafe { parsed[range].link = nil }
        return parsed
    }
}

private struct ToolsRow: View {
    let messages: [ConversationMessage]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10, weight: .semibold))
                    Text("ferramentas · \(messages.count)")
                        .font(Theme.Font.caption)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Theme.surfaceHi, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(messages) { message in
                        Text(message.text)
                            .font(Theme.Font.tool)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, Theme.Space.m)
                .transition(.opacity)
            }
        }
    }
}

private struct TypingRow: View {
    let name: String

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { index in
                        let wave = sin((t * 2 * .pi / 1.1) - Double(index) * 0.9)
                        Circle()
                            .fill(Theme.textSecondary)
                            .frame(width: 5, height: 5)
                            .opacity(0.45 + 0.55 * max(0, wave))
                            .offset(y: -2 * max(0, wave))
                    }
                }
            }
            Text("\(name) pensando…")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 30)
        .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
    }
}

/// A tool call the CLI holds until the user answers; one at a time, the rest wait behind it.
struct ApprovalCard: View {
    let request: PermissionRequest
    let queued: Int
    let answer: (PermissionDecision) -> Void
    @State private var expanded: Bool
    /// The full input was open at least once; until then a summary that can hide part of it holds Permitir.
    @State private var seenFull: Bool

    init(request: PermissionRequest, queued: Int, expanded: Bool = false, answer: @escaping (PermissionDecision) -> Void) {
        self.request = request
        self.queued = queued
        self.answer = answer
        _expanded = State(initialValue: expanded)
        _seenFull = State(initialValue: expanded)
    }

    private var locked: Bool { request.requiresExpansion && !seenFull }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Circle().fill(Theme.busy).frame(width: 7, height: 7)
                Text(ConversationReducer.awaitingApprovalStep)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                if queued > 0 {
                    Text("+\(queued) na fila")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Text("O Claude quer \(request.summary)")
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                let opening = !expanded
                withAnimation(.easeOut(duration: 0.18)) { expanded = opening }
                if opening { seenFull = true }
            } label: {
                HStack(spacing: 4) {
                    if locked {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                    }
                    Text(locked ? "comando longo — veja inteiro" : "detalhes")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(locked ? Theme.Font.bodyMedium : Theme.Font.caption)
                .foregroundStyle(locked ? Theme.busy : Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            if expanded {
                ScrollView {
                    Text(request.detail)
                        .font(Theme.Font.tool)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.s)
                }
                .frame(maxHeight: 220)
                .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                .transition(.opacity)
            }
            HStack(spacing: Theme.Space.s) {
                Button("Permitir") { answer(.allow) }
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(locked)
                    .help(locked ? "Abra o comando inteiro antes de permitir" : "")
                if request.canPersist {
                    Button("Sempre permitir") { answer(.allowAlways) }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                        .disabled(locked)
                        .help(locked ? "Abra o comando inteiro antes de permitir" : "Salva no Claude: \(request.persistRules.joined(separator: ", "))")
                }
                Spacer(minLength: 0)
                Button("Negar") { answer(.deny) }
                    .buttonStyle(CapsuleButtonStyle(kind: .error))
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.busy.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
    }
}

private struct FailureRow: View {
    let reason: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Circle().fill(Theme.error).frame(width: 7, height: 7)
            Text(reason)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: Theme.Space.s)
            Button("Retomar", action: retry)
                .buttonStyle(CapsuleButtonStyle(kind: .error))
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Theme.error.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
    }
}

/// Under a message in the outbox (D15): waiting, on its way, or not sent.
private struct HeldMarkRow: View {
    let mark: HeldMark
    let retry: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            if case .failed(let reason, _) = mark {
                Text(reason)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                switch mark {
                case .queued:
                    label("na fila")
                    Button("descartar", action: discard).buttonStyle(CapsuleButtonStyle(kind: .ghost))
                case .sending:
                    label("enviando…")
                case .failed(_, let canRetry):
                    Circle().fill(Theme.error).frame(width: 6, height: 6)
                    label("não enviada")
                    if canRetry { Button("tentar de novo", action: retry).buttonStyle(CapsuleButtonStyle(kind: .ghost)) }
                    Button("descartar", action: discard).buttonStyle(CapsuleButtonStyle(kind: .ghost))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textTertiary)
    }
}

private struct HeldRow: View {
    let reason: String

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Circle().fill(Theme.busy).frame(width: 7, height: 7)
            Text(reason)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.busy.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
    }
}

private struct HistorySkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Spacer(); Skeleton(cornerRadius: Theme.Radius.bubble).frame(width: 180, height: 34) }
            Skeleton(cornerRadius: Theme.Radius.bubble).frame(width: 260, height: 52)
            HStack { Spacer(); Skeleton(cornerRadius: Theme.Radius.bubble).frame(width: 140, height: 34) }
        }
    }
}
