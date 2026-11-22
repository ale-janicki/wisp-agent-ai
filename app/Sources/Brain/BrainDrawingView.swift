import AppKit
import SwiftUI

struct BrainDrawingView: View {
    let url: URL

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(url.lastPathComponent)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.s)
            Button("Abrir no app") { NSWorkspace.shared.open(url) }
                .buttonStyle(CompactCapsuleStyle(accent: false))
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
    }
}
