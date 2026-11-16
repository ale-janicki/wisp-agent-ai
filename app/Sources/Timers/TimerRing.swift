import SwiftUI

struct TimerRing: View {
    let fractionLeft: Double
    var size: CGFloat = 10
    var lineWidth: CGFloat = 2
    var color: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.textTertiary.opacity(0.5), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, fractionLeft)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
    }
}
