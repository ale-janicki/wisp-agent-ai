import SwiftUI
import WispCore

enum NoticeMotion {
    static let spring = Spring(response: 0.42, dampingRatio: 0.7)
    static let animation = Animation.spring(spring)
    static let settle: Duration = .seconds(spring.settlingDuration)
}

struct NoticeCard: View {
    let notice: Notice
    let badge: Int
    let avatarPath: String?
    let dismiss: () -> Void

    @State private var inviteError: String?

    private static let iconSize: CGFloat = 32

    /// Only the near-start meeting notice offers Entrar; the early one is just a heads-up.
    private var joinKey: String? {
        guard notice.kind == .meeting, notice.tone == .warning, case .event(let uid) = notice.target else { return nil }
        return uid
    }

    private var inviteKey: String? {
        guard notice.kind == .invite, notice.sourceId != Invites.moreSourceId, case .event(let uid) = notice.target else { return nil }
        return uid
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            icon
                .phaseAnimator([1.0, 1.14, 1.0], trigger: notice.time) { view, scale in
                    view.scaleEffect(scale)
                } animation: { scale in
                    scale > 1 ? .spring(response: 0.22, dampingFraction: 0.5) : .spring(response: 0.35, dampingFraction: 0.6)
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(notice.title)
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if badge > 0 {
                        Text("+\(badge)")
                            .font(Theme.Font.captionMono)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Theme.surfaceHi, in: Capsule())
                            .help(badge == 1 ? "mais 1 aviso na fila" : "mais \(badge) avisos na fila")
                    }
                    Spacer(minLength: Theme.Space.s)
                    Text(notice.time, format: .dateTime.hour().minute())
                        .font(Theme.Font.captionMono)
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(inviteError ?? notice.preview)
                    .font(Theme.Font.body)
                    .foregroundStyle(inviteError == nil ? Theme.textSecondary : Theme.error)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if joinKey != nil {
                Button("Entrar") {
                    guard let joinKey else { return }
                    Task { if await MeetingsCoordinator.shared.join(key: joinKey) { dismiss() } }
                }
                .buttonStyle(CapsuleButtonStyle(kind: .accent, size: .compact))
            }
            if let inviteKey {
                InviteActions(key: inviteKey, sourceId: notice.sourceId, error: $inviteError)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(CircleButtonStyle(kind: .plain, size: 20))
            .help("Dispensar")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var icon: some View {
        switch notice.kind {
        case .reply, .telegram:
            WispAvatar(size: Self.iconSize, animates: false, imagePath: avatarPath)
        case .reminder:
            symbol("bell.fill", tint: notice.tone == .alert ? Theme.error : Theme.busy)
        case .update:
            symbol("arrow.down.circle.fill", tint: Theme.accent)
        case .approval:
            symbol("hand.raised.fill", tint: Theme.busy)
        case .meeting:
            symbol("video.fill", tint: notice.tone == .warning ? Theme.busy : Theme.accent)
        case .invite:
            symbol("calendar.badge.plus", tint: Theme.accent)
        }
    }

    private func symbol(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: Self.iconSize, height: Self.iconSize)
            .background(tint.opacity(0.18), in: Circle())
    }
}
