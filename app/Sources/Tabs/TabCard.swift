import SwiftUI

struct TabCard<Content: View>: View {
    let title: String
    let icon: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                Text(title)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                if let trailing {
                    Text(trailing)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(height: 26)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder: String
    var autofocus = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark") }
                    .buttonStyle(CircleButtonStyle(size: 20))
                    .help("Limpar busca")
            }
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, 5)
        .frame(height: 30)
        .background(Capsule().fill(Theme.surfaceHi))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
        .onAppear { if autofocus { focused = true } }
    }
}

struct TabMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InlineError: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Circle().fill(Theme.error).frame(width: 7, height: 7)
            Text(text)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 7)
        .background(Theme.error.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
    }
}

struct SkeletonRows: View {
    var count = 4

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(0..<count, id: \.self) { _ in
                Skeleton(cornerRadius: Theme.Radius.nav).frame(height: 40)
            }
        }
    }
}

struct SectionCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConfirmAction: View {
    let label: String
    let question: String
    var busy = false
    let action: () -> Void
    @State private var asking = false

    var body: some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.small)
            } else if asking {
                Text(question)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Button("Sim") {
                    asking = false
                    action()
                }
                .buttonStyle(CompactCapsuleStyle(accent: true))
                Button("Não") { asking = false }
                    .buttonStyle(CompactCapsuleStyle(accent: false))
            } else {
                Button(label) { asking = true }
                    .buttonStyle(CompactCapsuleStyle(accent: false))
            }
        }
        .fixedSize()
    }
}

struct CompactCapsuleStyle: ButtonStyle {
    var accent: Bool

    func makeBody(configuration: Configuration) -> some View {
        CompactCapsuleBody(configuration: configuration, accent: accent)
    }
}

private struct CompactCapsuleBody: View {
    let configuration: ButtonStyleConfiguration
    let accent: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(Theme.Font.caption)
            .foregroundStyle(accent ? Theme.bg : Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { hovering = $0 }
            .pointerStyle(.link)
    }

    private var fill: Color {
        accent ? (hovering ? Theme.accentText : Theme.accent) : (hovering ? Theme.bg : Theme.surface)
    }
}
