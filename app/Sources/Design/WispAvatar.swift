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
        } else if animates, !reduceMotion {
            AnimatedWispFigure(size: size, busy: busy, accent: Theme.accent)
                .frame(width: size, height: size)
        } else {
            WispFigure(size: size, busy: busy, accent: Theme.accent)
        }
    }
}

private struct WispFigure: View {
    let size: CGFloat
    let busy: Bool
    let accent: Color

    var body: some View {
        ZStack {
            WispFigure.glow(size: size, accent: accent)
                .opacity(busy ? 0.6 : WispFigure.restGlow)
            WispFigure.shape(size: size, accent: accent)
            WispFigure.eyes(size: size)
        }
        .frame(width: size, height: size)
    }

    static let restGlow = 0.4

    static func gradient(_ accent: Color) -> LinearGradient {
        LinearGradient(colors: [accent, accent.mix(with: .white, by: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func glowRadius(_ size: CGFloat) -> CGFloat { size * 0.14 }

    static func glow(size: CGFloat, accent: Color) -> some View {
        WispShape()
            .fill(gradient(accent))
            .blur(radius: glowRadius(size))
            .frame(width: size, height: size)
    }

    static func shape(size: CGFloat, accent: Color) -> some View {
        ZStack {
            WispShape()
                .fill(gradient(accent))
            Ellipse()
                .fill(Theme.avatarSheen)
                .frame(width: size * 0.22, height: size * 0.14)
                .rotationEffect(.degrees(-30))
                .blur(radius: size * 0.04)
                .offset(x: -size * 0.14, y: -size * 0.02)
        }
        .frame(width: size, height: size)
    }

    static func eyeSize(_ size: CGFloat) -> CGSize {
        CGSize(width: max(1.6, size * 0.11), height: max(2.2, size * 0.17))
    }

    static func eyeSpacing(_ size: CGFloat) -> CGFloat { size * 0.1 }

    static func eyeDrop(_ size: CGFloat) -> CGFloat { size * 0.13 }

    static func eyes(size: CGFloat) -> some View {
        let eye = eyeSize(size)
        return HStack(spacing: eyeSpacing(size)) {
            Ellipse().fill(Theme.onAccent).frame(width: eye.width, height: eye.height)
            Ellipse().fill(Theme.onAccent).frame(width: eye.width, height: eye.height)
        }
        .offset(y: eyeDrop(size))
    }
}

private struct AnimatedWispFigure: NSViewRepresentable {
    let size: CGFloat
    let busy: Bool
    let accent: Color

    func makeNSView(context: Context) -> WispFigureLayerView { WispFigureLayerView() }

    func updateNSView(_ view: WispFigureLayerView, context: Context) {
        view.configure(size: size, busy: busy, accent: accent)
    }

    @MainActor
    final class WispFigureLayerView: NSView {
        private let lift = CALayer()
        private let glow = CALayer()
        private let shape = CALayer()
        private let glance = CALayer()
        private let blink = CALayer()
        private let eyes = [CAShapeLayer(), CAShapeLayer()]
        private var drawn: (size: CGFloat, accent: Color, scale: CGFloat)?
        private var animatedBusy: Bool?

        private static let frameRate = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        private static let blinkSlot: CFTimeInterval = 5.5
        private static let blinkSpread: CFTimeInterval = 1.5
        private static let blinkLength: CFTimeInterval = 0.16
        private static let blinkSlots = 3

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            guard let root = layer else { return }
            root.masksToBounds = false
            lift.anchorPoint = CGPoint(x: 0.5, y: 0)
            root.addSublayer(lift)
            lift.addSublayer(glow)
            lift.addSublayer(shape)
            lift.addSublayer(glance)
            glance.addSublayer(blink)
            for eye in eyes { blink.addSublayer(eye) }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isFlipped: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            if let drawn { configure(size: drawn.size, busy: animatedBusy ?? false, accent: drawn.accent) }
        }

        func configure(size: CGFloat, busy: Bool, accent: Color) {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if drawn?.size != size || drawn?.accent != accent || drawn?.scale != scale {
                draw(size: size, accent: accent, scale: scale)
                drawn = (size, accent, scale)
                animatedBusy = nil
            }
            if animatedBusy != busy {
                animate(size: size, busy: busy)
                animatedBusy = busy
            }
            CATransaction.commit()
        }

        private func draw(size: CGFloat, accent: Color, scale: CGFloat) {
            let bounds = CGRect(x: 0, y: 0, width: size, height: size)
            lift.bounds = bounds
            lift.position = CGPoint(x: size / 2, y: 0)
            let pad = ceil(WispFigure.glowRadius(size) * 3)
            glow.frame = bounds.insetBy(dx: -pad, dy: -pad)
            glow.contents = Self.image(WispFigure.glow(size: size, accent: accent).padding(pad), scale: scale)
            glow.contentsScale = scale
            shape.frame = bounds
            shape.contents = Self.image(WispFigure.shape(size: size, accent: accent), scale: scale)
            shape.contentsScale = scale

            let eye = WispFigure.eyeSize(size)
            let spacing = WispFigure.eyeSpacing(size)
            let centerY = size / 2 - WispFigure.eyeDrop(size)
            glance.frame = bounds
            blink.bounds = bounds
            blink.anchorPoint = CGPoint(x: 0.5, y: centerY / size)
            blink.position = CGPoint(x: size / 2, y: centerY)
            let color = NSColor(Theme.onAccent).cgColor
            for (index, layer) in eyes.enumerated() {
                let side: CGFloat = index == 0 ? -1 : 1
                let midX = size / 2 + side * (eye.width + spacing) / 2
                let rect = CGRect(x: midX - eye.width / 2, y: centerY - eye.height / 2, width: eye.width, height: eye.height)
                layer.frame = bounds
                layer.path = CGPath(ellipseIn: rect, transform: nil)
                layer.fillColor = color
                layer.contentsScale = scale
            }
        }

        private func animate(size: CGFloat, busy: Bool) {
            for layer in [lift, glow, glance, blink] { layer.removeAllAnimations() }
            let rise = min(1.5, size * 0.06)
            let breathe = CABasicAnimation(keyPath: "transform")
            breathe.fromValue = CATransform3DIdentity
            breathe.toValue = CATransform3DScale(CATransform3DMakeTranslation(0, rise, 0), 1.03, 1.03, 1)
            lift.add(Self.looping(breathe, half: 1.5), forKey: "breathe")
            blink.add(Self.blinks(), forKey: "blink")
            if busy {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 0.25
                pulse.toValue = 0.75
                glow.opacity = 0.5
                glow.add(Self.looping(pulse, half: 0.8), forKey: "pulse")
                let look = CABasicAnimation(keyPath: "transform.translation.x")
                look.fromValue = -size * 0.05
                look.toValue = size * 0.05
                glance.add(Self.looping(look, half: 1.2), forKey: "glance")
            } else {
                glow.opacity = Float(WispFigure.restGlow)
            }
        }

        private static func looping(_ animation: CABasicAnimation, half: CFTimeInterval) -> CABasicAnimation {
            animation.duration = half
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.preferredFrameRateRange = frameRate
            animation.isRemovedOnCompletion = false
            return animation
        }

        private static func blinks() -> CAKeyframeAnimation {
            let period = blinkSlot * Double(blinkSlots)
            var times: [NSNumber] = [0]
            var values: [NSNumber] = [1]
            for slot in 0..<blinkSlots {
                let start = Double(slot) * blinkSlot + hash(Double(slot)) * blinkSpread
                for (offset, value) in [(0.0, 1.0), (blinkLength / 2, 0.12), (blinkLength, 1.0)] {
                    times.append(NSNumber(value: (start + offset) / period))
                    values.append(NSNumber(value: value))
                }
            }
            times.append(1)
            values.append(1)
            let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
            animation.keyTimes = times
            animation.values = values
            animation.duration = period
            animation.repeatCount = .infinity
            animation.preferredFrameRateRange = frameRate
            animation.isRemovedOnCompletion = false
            return animation
        }

        private static func hash(_ slot: Double) -> Double {
            let x = sin(slot * 12.9898 + 78.233) * 43758.5453
            return x - floor(x)
        }

        private static func image(_ view: some View, scale: CGFloat) -> CGImage? {
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            return renderer.cgImage
        }
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
