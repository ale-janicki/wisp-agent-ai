import SwiftUI

struct Skeleton: View {
    var cornerRadius: CGFloat = Theme.Radius.artwork

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.surfaceHi)
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, Theme.highlight, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: (phase * 1.6 - 0.6) * geo.size.width)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
