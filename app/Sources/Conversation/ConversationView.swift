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
                                case .tools(let group): ToolsRow(messages: group)
                                }
                            }
                            if let request = model.approvalQueue.first {
                                ApprovalCard(request: request, queued: model.approvalQueue.count - 1) { model.answer(request, $0) }
                                    .id(request.id)
                            } else if model.isThinking {
                                TypingRow(text: model.waitingForTelegram ? ConversationViewModel.waitingStep : "\(model.personaName) pensando…")
                            }
                            if case .failed(let reason) = model.state.phase {
                                FailureRow(reason: reason) { model.retry() }
                            }
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
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    if !message.text.isEmpty {
                        assistantBubble
                            .environment(\.openURL, OpenURLAction { url in
                                url.isFileURL ? Self.openFile(url) : .systemAction
                            })
                    }
                    if lineLimit == nil, !message.files.isEmpty {
                        FileCards(paths: message.files, maxWidth: maxWidth)
                    }
                }
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

    @ViewBuilder
    private var assistantBubble: some View {
        if lineLimit != nil {
            bubble(Text(Self.markdown(message.text)), fill: Theme.surfaceHi)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Array(Self.segments(of: message).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let text):
                        Text(Self.markdown(text))
                    case .code(let code):
                        let block = Text(code.isEmpty ? " " : code)
                            .font(Theme.Font.tool)
                            .lineSpacing(1)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(Theme.Space.s)
                        ViewThatFits(in: .horizontal) {
                            block
                            ScrollView(.horizontal) { block }.scrollIndicators(.hidden)
                        }
                        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
                    case .table(let header, let rows):
                        ChatTable(header: header, rows: rows)
                    }
                }
            }
            .font(Theme.Font.body)
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.accentText)
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 9)
            .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
        }
    }

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

    private final class SegmentBox {
        let text: String
        let segments: [ChatMarkdown.Segment]
        init(text: String, segments: [ChatMarkdown.Segment]) {
            self.text = text
            self.segments = segments
        }
    }

    private static let segmentCache: NSCache<NSUUID, SegmentBox> = {
        let cache = NSCache<NSUUID, SegmentBox>()
        cache.countLimit = 400
        return cache
    }()

    private static func segments(of message: ConversationMessage) -> [ChatMarkdown.Segment] {
        let key = message.id as NSUUID
        if let hit = segmentCache.object(forKey: key), hit.text == message.text { return hit.segments }
        let segments = ChatMarkdown.segments(message.text)
        segmentCache.setObject(SegmentBox(text: message.text, segments: segments), forKey: key)
        return segments
    }

    fileprivate static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var parsed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        let unsafe = parsed.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link else { return nil }
            return isOpenable(url) ? nil : run.range
        }
        for range in unsafe { parsed[range].link = nil }
        return parsed
    }

    private static func isOpenable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return true
        case "file": return url.path.hasPrefix("/") && [nil, "", "localhost"].contains(url.host)
        default: return false
        }
    }

    static func openFile(_ url: URL) -> OpenURLAction.Result {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = resolved.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .discarded }
        let action = FileOpenPolicy.action(pathExtension: resolved.pathExtension,
                                           isExecutable: !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path),
                                           isDirectory: isDirectory.boolValue)
        switch action {
        case .open: NSWorkspace.shared.open(resolved)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([resolved])
        }
        return .handled
    }
}

private struct ChatTable: View {
    let header: [String]
    let rows: [[String]]

    private func cell(_ text: String, bold: Bool) -> some View {
        Text(MessageRow.markdown(text))
            .fontWeight(bold ? .semibold : .regular)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }

    var body: some View {
        let grid = Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, text in cell(text, bold: true) }
            }
            .background(Color.black.opacity(0.22))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, text in cell(text, bold: false) }
                }
                .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1) }
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) { grid }.scrollIndicators(.hidden)
        }
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
    let text: String
    @State private var since = Date()

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
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Self.label(text, elapsed: context.date.timeIntervalSince(since)))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 30)
        .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
    }

    static func label(_ text: String, elapsed: TimeInterval) -> String {
        elapsed >= 5 ? "\(text) \(Int(elapsed)) s" : text
    }
}

struct ApprovalCard: View {
    let request: PermissionRequest
    let queued: Int
    let answer: (PermissionDecision) -> Void
    @State private var expanded: Bool
    @State private var seenFull: Bool

    init(request: PermissionRequest, queued: Int, expanded: Bool = false, answer: @escaping (PermissionDecision) -> Void) {
        self.request = request
        self.queued = queued
        self.answer = answer
        _expanded = State(initialValue: expanded)
        _seenFull = State(initialValue: expanded)
    }

    private var locked: Bool { request.requiresExpansion && !seenFull }
    private var lockedLabel: String {
        request.toolName == "Bash" || request.toolName == "PowerShell" ? "comando longo — veja inteiro" : "veja o conteúdo inteiro"
    }

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
            Text("O \(request.asker) quer \(request.summary)")
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
                    Text(locked ? lockedLabel : "detalhes")
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

private struct HistorySkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Spacer(); Skeleton(cornerRadius: Theme.Radius.bubble).frame(width: 180, height: 34) }
            Skeleton(cornerRadius: Theme.Radius.bubble).frame(width: 260, height: 52)
            HStack { Spacer(); Skeleton(cornerRadius: Theme.Radius.bubble).frame(width: 140, height: 34) }
        }
    }
}
