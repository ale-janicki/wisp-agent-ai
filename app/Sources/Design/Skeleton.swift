import SwiftUI

struct Skeleton: View {
    var cornerRadius: CGFloat = Theme.Radius.artwork
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            shape.fill(Theme.surfaceHi)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                shape
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
                    .clipShape(shape)
            }
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
}

struct SkeletonLines: View {
    var count = 4
    var lineHeight: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(0..<count, id: \.self) { index in
                Skeleton(cornerRadius: 4)
                    .frame(height: lineHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, index == count - 1 ? 80 : 0)
            }
        }
    }
}

private struct SkeletonOverlay: ViewModifier {
    let isLoading: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(isLoading ? 0 : 1)
            .overlay {
                if isLoading { Skeleton(cornerRadius: cornerRadius).allowsHitTesting(false) }
            }
            .allowsHitTesting(!isLoading)
    }
}

extension View {
    func skeleton(isLoading: Bool, cornerRadius: CGFloat = Theme.Radius.artwork) -> some View {
        modifier(SkeletonOverlay(isLoading: isLoading, cornerRadius: cornerRadius))
    }
}

enum SkeletonPattern {
    struct Span {
        let start: Double
        let length: Double
    }

    static func spans(seed: Int) -> [Span] {
        var state = UInt64(bitPattern: Int64(seed)) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 33) / Double(1 << 31)
        }
        var cursor = 8 + next() * 1.5
        var spans: [Span] = []
        while spans.count < 3, cursor < 18 {
            let length = 0.75 + next() * 1.5
            spans.append(Span(start: cursor, length: length))
            cursor += length + 0.5 + next() * 1.5
        }
        return spans
    }

    static func chips(seed: Int) -> Int { 1 + abs(seed) % 3 }
}
