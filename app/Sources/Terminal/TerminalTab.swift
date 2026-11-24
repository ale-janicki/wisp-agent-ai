import SwiftUI
import WispCore

/// The Terminal tab: a strip of sessions on top and the selected session's screen under it. Compact in the notch panel, with a
/// bigger font in the window; the screen fills whatever room the container has.
struct TerminalTab: View {
    private let workspace = TerminalStore.shared.workspace
    @Environment(\.windowMode) private var windowMode

    var body: some View {
        VStack(spacing: 0) {
            strip
            Divider().overlay(Theme.stroke)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.stroke) }
        .onAppear { workspace.openFirstIfNeeded() }
        .onDisappear { workspace.rememberDirectories() }
    }

    // MARK: Strip

    private var strip: some View {
        HStack(spacing: Theme.Space.xs) {
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(workspace.sessions) { session in
                        chip(session)
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button {
                workspace.openSession()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
            .help("Nova sessão (⌘T)")
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 38)
    }

    private func chip(_ session: TerminalSession) -> some View {
        let selected = workspace.selectedID == session.id
        return HStack(spacing: Theme.Space.xs) {
            Button {
                workspace.select(session.id)
            } label: {
                Text(session.name)
                    .font(Theme.Font.caption)
                    .foregroundStyle(selected ? Theme.accentText : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160)
            }
            .buttonStyle(.plain)
            .help(session.directory)
            Button {
                workspace.close(session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Fechar sessão (⌘W)")
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 24)
        .background(selected ? Theme.accentFill : Color.clear, in: Capsule())
        .pointerStyle(.link)
    }

    // MARK: Screen

    @ViewBuilder
    private var content: some View {
        if let session = workspace.selected, let engine = session.engine as? SwiftTermEngine {
            VStack(spacing: 0) {
                TerminalSurface(engine: engine, fontSize: windowMode ? TerminalTheme.windowFontSize : TerminalTheme.compactFontSize)
                    .id(session.id)
                    .padding(.leading, Theme.Space.s)
                if let note = endedNote(session) {
                    HStack(spacing: Theme.Space.m) {
                        Text(note)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Button("Reabrir") { session.reopen() }
                            .buttonStyle(CapsuleButtonStyle(kind: .accent, size: .compact))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .frame(height: 38)
                    .background(Theme.surface)
                }
            }
        } else {
            VStack(spacing: Theme.Space.m) {
                Text("Nenhuma sessão aberta")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                Button("Nova sessão") { workspace.openSession() }
                    .buttonStyle(CapsuleButtonStyle(kind: .accent))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func endedNote(_ session: TerminalSession) -> String? {
        switch session.phase {
        case .ended(let code): code.map { "Código de saída \($0)" } ?? "Encerrado por um sinal"
        case .failed(let reason): reason
        case .idle, .running: nil
        }
    }
}
