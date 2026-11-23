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
    @ObservedObject private var meetings: MeetingRecordingModel

    init(controller: ShellController) {
        self.controller = controller
        _media = ObservedObject(wrappedValue: controller.media)
        _meetings = ObservedObject(wrappedValue: controller.meetings)
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
        .animation(Self.drop, value: noticeKey)
        .onChange(of: screenKey) { controller.notices.prune() }
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
            if let notice = controller.notices.current {
                panelNotice(notice)
                    .padding(.top, controller.pillBand.height + Theme.Space.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .clipShape(panelShape)
    }

    /// With the panel open on another tab the card floats over it, under the notch.
    private func panelNotice(_ notice: Notice) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return NoticeCard(notice: notice, badge: controller.notices.queue.badge, avatarPath: avatarPath) {
            controller.notices.dismiss()
        }
        .frame(width: NotchGeometry.noticeSize.width, height: NotchGeometry.noticeSize.height)
        .background(Theme.surface.opacity(0.82), in: shape)
        .glass(cornerRadius: Theme.Radius.card)
        .contentShape(shape)
        .onTapGesture { controller.notices.open() }
        .onHover { controller.notices.hover($0) }
        .pointerStyle(.link)
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
        let drop = controller.pillDrop
        let notice = controller.presentsNotice ? controller.notices.current : nil
        let shape = PillShape(band: band, drop: drop, progress: controller.pillExpanded ? 1 : 0, radius: controller.pillRadius)
        return ZStack(alignment: .top) {
            shape.fill(Theme.notch)
            shape.stroke(Theme.accent, lineWidth: 1.5)
                .phaseAnimator([0.0, 0.7, 0.0], trigger: controller.notices.arrivals) { glow, phase in
                    glow.opacity(phase)
                } animation: { phase in
                    phase > 0 ? .easeOut(duration: 0.25) : .easeIn(duration: 1.1)
                }
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                bandContent.frame(width: band.width, height: band.height)
                if let notice {
                    NoticeCard(notice: notice, badge: controller.notices.queue.badge, avatarPath: avatarPath) {
                        controller.notices.dismiss()
                    }
                    .frame(width: drop.width, height: drop.height)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -8)).animation(Self.drop.delay(0.08)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))
                    ))
                } else if isActive {
                    replyLine
                        .frame(width: NotchGeometry.activeWidth - 2 * Theme.Space.l, height: NotchGeometry.stripHeight)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: max(drop.width, band.width), height: band.height + drop.height, alignment: .top)
        .contentShape(shape)
        .onTapGesture {
            if notice != nil { controller.notices.open() } else { controller.pillClicked() }
        }
        .pointerStyle(notice != nil ? .link : nil)
    }
}

extension PillView {
    /// A little bounce when the card lands; the content follows the shape with a short delay.
    fileprivate static let drop = NoticeMotion.animation

    fileprivate var avatarPath: String? { controller.conversation.profile.persona.avatar }

    /// Changes when a card arrives at the notch, so the shape, the glow and the content animate once per card.
    fileprivate var noticeKey: String? {
        guard controller.presentsNotice, let notice = controller.notices.current else { return nil }
        return "\(notice.sourceId)|\(notice.time.timeIntervalSince1970)"
    }

    /// Everything that decides what the user is looking at, plus the switches: a change prunes the queue.
    fileprivate var screenKey: NoticeScreenKey {
        let model = controller.conversation
        return NoticeScreenKey(
            state: controller.state, tab: controller.tab, conversation: model.currentId, thread: model.linkedThread,
            settings: AppSettings.shared.settings.notices
        )
    }
}

private struct NoticeScreenKey: Equatable {
    var state: PillState
    var tab: PanelTab
    var conversation: UUID
    var thread: Int?
    var settings: NoticeSettings
}

extension PillView {
    private static let wingWidth: CGFloat = 36

    private var avatar: some View {
        let busy = controller.statusColor == .busy
        return WispAvatar(
            size: 16,
            busy: busy,
            animates: !controller.presentsNotice,
            imagePath: controller.conversation.profile.persona.avatar
        )
        .opacity(controller.presentsNotice ? 0 : 1)
        #if DEBUG
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { controller.debugReport("avatar", $0) })
        #endif
    }

    /// Only what needs a look: an unseen notice (its tone) or a conversation in error.
    private var dotColor: Color? {
        if let tone = controller.notices.unseen {
            switch tone {
            case .normal: return Theme.accent
            case .warning: return Theme.busy
            case .alert: return Theme.error
            }
        }
        return controller.statusColor == .error ? Theme.error : nil
    }

    @ViewBuilder
    private var dot: some View {
        if let color = dotColor {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.6), radius: 3)
                #if DEBUG
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { controller.debugReport("dot", $0) })
                #endif
        }
    }

    private var statusWing: some View {
        HStack(spacing: 5) {
            if meetings.startedAt != nil {
                RecordingIndicator(warns: !meetings.warnings.isEmpty, paused: meetings.isPaused)
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
    var radius: CGFloat = Theme.Radius.pill

    /// The drop and the corner animate too, so the strip morphs into the notice card and back.
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get { AnimatablePair(progress, AnimatablePair(AnimatablePair(drop.width, drop.height), radius)) }
        set {
            progress = newValue.first
            drop = CGSize(width: newValue.second.first.first, height: newValue.second.first.second)
            radius = newValue.second.second
        }
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
        let radius = min(self.radius, band.width / 2, bottom - top - (shoulder > 0 ? band.height + corner : 0))

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

private struct RecordingIndicator: View {
    let warns: Bool
    let paused: Bool

    var body: some View {
        RecordingDot(warns: warns, paused: paused, size: 8)
            .accessibilityLabel(paused ? "Gravação da reunião pausada" : (warns ? "Gravando reunião, com aviso" : "Gravando reunião"))
    }
}

struct RecordingDot: View {
    let warns: Bool
    var paused = false
    var size: CGFloat = 7

    var body: some View {
        if paused {
            Image(systemName: "pause.fill")
                .font(.system(size: size - 1, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: size, height: size)
        } else {
            Circle()
                .fill(warns ? Theme.busy : Theme.error)
                .frame(width: size, height: size)
                .shadow(color: (warns ? Theme.busy : Theme.error).opacity(0.6), radius: 3)
                .phaseAnimator([1.0, 0.35]) { dot, opacity in
                    dot.opacity(opacity)
                } animation: { _ in .easeInOut(duration: 0.8) }
        }
    }
}
