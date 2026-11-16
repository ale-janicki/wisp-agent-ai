import AppKit
import SwiftUI
import WispCore

struct WispAvatar: View {
    var size: CGFloat
    var busy = false
    var animates = true
    var imagePath: String?

    var body: some View {
        if let image = AvatarImageCache.image(at: imagePath) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { context in
                WispFigure(size: size, busy: busy, time: context.date.timeIntervalSinceReferenceDate)
            }
            .frame(width: size, height: size)
        }
    }
}

private struct WispFigure: View {
    let size: CGFloat
    let busy: Bool
    let time: TimeInterval

    private static let gradient = LinearGradient(
        colors: [Theme.accent, Theme.accentTeal],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private var breath: CGFloat { 1 + 0.015 * (1 - cos(2 * .pi * time / 3)) }

    private var glance: CGFloat { busy ? sin(2 * .pi * time / 2.4) * size * 0.05 : 0 }

    private var eyeOpen: CGFloat {
        guard busy else { return 1 }
        let phase = time.truncatingRemainder(dividingBy: 2.6)
        guard phase < 0.16 else { return 1 }
        return max(0.12, abs(cos(phase / 0.16 * .pi)))
    }

    var body: some View {
        ZStack {
            WispShape()
                .fill(Self.gradient)
                .blur(radius: size * 0.14)
                .opacity(0.55)
            WispShape()
                .fill(Self.gradient)
            Ellipse()
                .fill(Theme.avatarSheen)
                .frame(width: size * 0.22, height: size * 0.14)
                .rotationEffect(.degrees(-30))
                .blur(radius: size * 0.04)
                .offset(x: -size * 0.14, y: -size * 0.02)
            eyes
        }
        .frame(width: size, height: size)
        .scaleEffect(breath, anchor: .bottom)
    }

    private var eyes: some View {
        HStack(spacing: size * 0.1) {
            eye
            eye
        }
        .offset(x: glance, y: size * 0.13)
    }

    private var eye: some View {
        Ellipse()
            .fill(Theme.onAccent)
            .frame(width: max(1.6, size * 0.11), height: max(2.2, size * 0.17) * eyeOpen)
    }
}

private struct WispShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0.62, 0.02))
        path.addCurve(to: p(0.88, 0.58), control1: p(0.70, 0.22), control2: p(0.90, 0.36))
        path.addCurve(to: p(0.50, 0.97), control1: p(0.88, 0.82), control2: p(0.70, 0.97))
        path.addCurve(to: p(0.12, 0.60), control1: p(0.28, 0.97), control2: p(0.12, 0.82))
        path.addCurve(to: p(0.42, 0.20), control1: p(0.12, 0.42), control2: p(0.28, 0.30))
        path.addCurve(to: p(0.62, 0.02), control1: p(0.52, 0.13), control2: p(0.60, 0.10))
        path.closeSubpath()
        return path
    }
}

@MainActor
private enum AvatarImageCache {
    private static var cache: [String: NSImage] = [:]

    static func image(at path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = expandTilde(path)
        if let cached = cache[expanded] { return cached }
        guard let image = NSImage(contentsOfFile: expanded) else { return nil }
        cache[expanded] = image
        return image
    }
}
