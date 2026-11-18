import AppKit
import SwiftUI
import WispCore

struct WispAvatar: View {
    var size: CGFloat
    var busy = false
    var animates = true
    var imagePath: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let image = AvatarImageCache.image(at: imagePath) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        } else {
            let accent = Theme.accent
            let gradient = LinearGradient(
                colors: [accent, accent.mix(with: .white, by: 0.4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates || reduceMotion)) { context in
                WispFigure(
                    size: size,
                    busy: busy,
                    gradient: gradient,
                    glow: accent,
                    time: reduceMotion ? nil : context.date.timeIntervalSinceReferenceDate
                )
            }
            .frame(width: size, height: size)
        }
    }
}

/// `time` nil is the still figure ("Reduzir movimento"): no float, breath, blink or glance.
private struct WispFigure: View {
    let size: CGFloat
    let busy: Bool
    let gradient: LinearGradient
    let glow: Color
    let time: TimeInterval?

    private static let blinkSlot: TimeInterval = 5.5
    private static let blinkSpread: TimeInterval = 1.5
    private static let blinkLength: TimeInterval = 0.16

    private var t: TimeInterval { time ?? 0 }

    private var breath: CGFloat { 1 + 0.015 * (1 - cos(2 * .pi * t / 3)) }

    /// Floats up to 1.5 pt over 3 s; scales with the figure so a 16 pt pill avatar and a 36 pt panel one read alike.
    private var float: CGFloat { -min(1.5, size * 0.06) * (1 - cos(2 * .pi * t / 3)) / 2 }

    private var glance: CGFloat { busy ? sin(2 * .pi * t / 2.4) * size * 0.05 : 0 }

    /// Soft pulse while the agent works; a steady mid glow when still.
    private var glowOpacity: Double {
        guard busy else { return 0.4 }
        guard time != nil else { return 0.6 }
        return 0.5 + 0.25 * sin(2 * .pi * t / 1.6)
    }

    /// One blink per slot at a pseudo-random spot, so the gap between two blinks is 4 to 7 s.
    private var eyeOpen: CGFloat {
        guard time != nil else { return 1 }
        let slot = floor(t / Self.blinkSlot)
        let into = t - slot * Self.blinkSlot
        let start = Self.hash(slot) * Self.blinkSpread
        let phase = into - start
        guard phase >= 0, phase < Self.blinkLength else { return 1 }
        return max(0.12, abs(cos(phase / Self.blinkLength * .pi)))
    }

    private static func hash(_ slot: Double) -> Double {
        let x = sin(slot * 12.9898 + 78.233) * 43758.5453
        return x - floor(x)
    }

    var body: some View {
        ZStack {
            WispShape()
                .fill(gradient)
                .blur(radius: size * 0.14)
                .opacity(glowOpacity)
            WispShape()
                .fill(gradient)
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
        .offset(y: float)
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
