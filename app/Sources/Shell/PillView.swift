import AppKit
import SwiftUI
import WispCore

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var hitShape: (@MainActor (CGSize) -> CGPath?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let shape = hitShape?(bounds.size) else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let flipped = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        return shape.contains(flipped) ? super.hitTest(point) : nil
    }
}

struct PillView: View {
    @ObservedObject var controller: ShellController
    @ObservedObject private var media: NowPlayingService
    @ObservedObject private var timers: TimerService

    init(controller: ShellController) {
        self.controller = controller
        _media = ObservedObject(wrappedValue: controller.media)
        _timers = ObservedObject(wrappedValue: controller.timers)
    }

    private var isPanel: Bool { controller.state == .panel }
    private var isActive: Bool { controller.state == .active }

    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: Theme.Radius.panel,
            bottomTrailingRadius: Theme.Radius.panel,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    var body: some View {
        Color.clear
            .overlay(alignment: .top) {
                if isPanel {
                    panelContainer.transition(.opacity)
                } else {
                    pill.transition(.opacity)
                }
            }
            .ignoresSafeArea()
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: controller.state)
        #if DEBUG
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { controller.debugReport("root", $0) })
        #endif
    }

    private var panelContainer: some View {
        ZStack(alignment: .top) {
            panelShape.fill(panelFill)
            panelShape.strokeBorder(
                LinearGradient(colors: [Theme.highlight, Theme.highlight.opacity(0.4)], startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
            PanelView(controller: controller, media: media, model: controller.conversation)
        }
        .clipShape(panelShape)
    }

    private var panelFill: AnyShapeStyle {
        guard controller.notchWidth > 0 else { return AnyShapeStyle(Theme.bg) }
        return AnyShapeStyle(LinearGradient(
            stops: [.init(color: Theme.notch, location: 0), .init(color: Theme.bg, location: 0.1)],
            startPoint: .top,
            endPoint: .bottom
        ))
    }

    private var pill: some View {
        let band = controller.pillBand
        let shape = PillShape(
            band: band,
            drop: CGSize(width: NotchGeometry.activeWidth, height: NotchGeometry.stripHeight),
            progress: isActive ? 1 : 0
        )
        return ZStack(alignment: .top) {
            shape.fill(Theme.notch)
            if controller.timerPulse {
                shape.stroke(Theme.accent, lineWidth: 1.5)
                    .phaseAnimator([0.15, 0.9]) { outline, phase in outline.opacity(phase) } animation: { _ in .easeInOut(duration: 0.6) }
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                bandContent.frame(width: band.width, height: band.height)
                if isActive {
                    replyLine
                        .frame(width: NotchGeometry.activeWidth - 2 * Theme.Space.l, height: NotchGeometry.stripHeight)
                        .transition(.opacity)
                }
            }
        }
        .frame(
            width: max(NotchGeometry.activeWidth, band.width),
            height: band.height + NotchGeometry.stripHeight,
            alignment: .top
        )
        .contentShape(shape)
        .onTapGesture { controller.pillClicked() }
    }
}

extension PillView {
    private static let wingWidth: CGFloat = 36

    private var avatar: some View {
        let busy = controller.statusColor == .busy
        return WispAvatar(
            size: 16,
            busy: busy,
            animates: busy,
            imagePath: controller.conversation.profile.persona.avatar
        )
        #if DEBUG
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { controller.debugReport("avatar", $0) })
        #endif
    }

    private var dot: some View {
        Circle()
            .fill(controller.statusColor.color)
            .frame(width: 7, height: 7)
            .shadow(color: controller.statusColor.color.opacity(0.6), radius: 3)
            #if DEBUG
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { controller.debugReport("dot", $0) })
            #endif
    }

    private var statusWing: some View {
        HStack(spacing: 5) {
            if controller.timerPulse {
                TimerRing(fractionLeft: 1)
                    .phaseAnimator([0.3, 1.0]) { ring, phase in ring.opacity(phase) } animation: { _ in .easeInOut(duration: 0.6) }
            } else if let timer = timers.list.soonest {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    TimerRing(fractionLeft: timer.fractionLeft(at: context.date))
                }
            } else if media.isPlaying, controller.statusColor == .ok {
                EqualizerBars()
            }
            dot
        }
    }

    @ViewBuilder
    fileprivate var bandContent: some View {
        if controller.restHasNotch {
            HStack(spacing: 0) {
                avatar.frame(width: Self.wingWidth)
                Spacer(minLength: 0)
                statusWing.frame(width: Self.wingWidth)
            }
            #if DEBUG
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { controller.debugReport("band", $0) })
            #endif
        } else {
            HStack {
                avatar
                Spacer(minLength: 0)
                statusWing
            }
            .padding(.horizontal, Theme.Space.m)
        }
    }

    private var replyLine: some View {
        Text(controller.pillText ?? "")
            .font(Theme.Font.bodyMedium)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

struct PillShape: Shape {
    var band: CGSize
    var drop: CGSize
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = min(max(progress, 0), 1)
        let top = rect.minY
        let bandBottom = top + band.height
        let bottom = bandBottom + drop.height * min(1, p * 2)
        let shoulder = max(0, (drop.width - band.width) / 2) * max(0, p * 2 - 1)
        let bandLeft = rect.midX - band.width / 2
        let bandRight = rect.midX + band.width / 2
        let corner = min(Theme.Radius.pillShoulder, shoulder / 2)
        let radius = min(Theme.Radius.pill, band.width / 2, bottom - top - (shoulder > 0 ? band.height + corner : 0))

        var path = Path()
        path.move(to: CGPoint(x: bandLeft, y: top))
        path.addLine(to: CGPoint(x: bandRight, y: top))
        guard shoulder > 0 else {
            path.addArc(tangent1End: CGPoint(x: bandRight, y: bottom), tangent2End: CGPoint(x: rect.midX, y: bottom), radius: radius)
            path.addArc(tangent1End: CGPoint(x: bandLeft, y: bottom), tangent2End: CGPoint(x: bandLeft, y: top), radius: radius)
            path.closeSubpath()
            return path
        }
        let outRight = bandRight + shoulder
        let outLeft = bandLeft - shoulder
        path.addArc(tangent1End: CGPoint(x: bandRight, y: bandBottom), tangent2End: CGPoint(x: outRight, y: bandBottom), radius: corner)
        path.addArc(tangent1End: CGPoint(x: outRight, y: bandBottom), tangent2End: CGPoint(x: outRight, y: bottom), radius: corner)
        path.addArc(tangent1End: CGPoint(x: outRight, y: bottom), tangent2End: CGPoint(x: rect.midX, y: bottom), radius: radius)
        path.addArc(tangent1End: CGPoint(x: outLeft, y: bottom), tangent2End: CGPoint(x: outLeft, y: bandBottom), radius: radius)
        path.addArc(tangent1End: CGPoint(x: outLeft, y: bandBottom), tangent2End: CGPoint(x: bandLeft, y: bandBottom), radius: corner)
        path.addArc(tangent1End: CGPoint(x: bandLeft, y: bandBottom), tangent2End: CGPoint(x: bandLeft, y: top), radius: corner)
        path.closeSubpath()
        return path
    }
}

private struct EqualizerBars: View {
    private static let phases: [Double] = [0, 1.7, 3.1]
    private static let speeds: [Double] = [7.0, 9.5, 8.2]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 2, height: 3 + 6 * abs(sin(t * Self.speeds[index] / 2 + Self.phases[index])))
                }
            }
            .frame(height: 9, alignment: .bottom)
        }
    }
}
