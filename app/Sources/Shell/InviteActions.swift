import Observation
import SwiftUI
import WispCore

/// The invitations still pending on the calendar, observable so a card reacts when its invite is answered elsewhere.
@MainActor @Observable
final class PendingInvites {
    static let shared = PendingInvites()

    var events: [CalEvent] = []

    func event(key: String) -> CalEvent? { events.first { $0.uid == key } }
}

/// The answer controls of an invitation card: Sim / Talvez / Não when a connected Google account can answer,
/// otherwise a single Responder that opens the event in the Agenda.
struct InviteActions: View {
    let key: String
    let sourceId: String
    @Binding var error: String?

    @State private var busy = false
    private let google = GoogleModel.shared
    private let pending = PendingInvites.shared

    static let hint = "Conecte o Google para responder aqui"

    var body: some View {
        if let event = pending.event(key: key), google.account(for: event) != nil {
            choices(for: event)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Button("Responder") {
                    MeetingsCoordinator.shared.openEvent(key: key)
                    MeetingsCoordinator.shared.dismissNotice(sourceId: sourceId)
                }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost, size: .compact))
                if !google.isConnected {
                    Text(Self.hint)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(width: 112, alignment: .trailing)
                        .help(Self.hint)
                }
            }
        }
    }

    /// Three answers in one capsule: three separate compact capsules would take 150 pt of the card's 312 pt, this takes about 118.
    private func choices(for event: CalEvent) -> some View {
        ZStack {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 0) {
                    ForEach(GoogleRSVPChoice.allCases, id: \.self) { choice in
                        ChoiceButton(label: choice.label) { respond(event, choice) }
                    }
                }
            }
        }
        .frame(height: Theme.Control.compactHeight)
        .background(Capsule().fill(Theme.surfaceHi.opacity(0.6)))
    }

    private func respond(_ event: CalEvent, _ choice: GoogleRSVPChoice) {
        guard !busy else { return }
        busy = true
        error = nil
        let sourceId = sourceId
        Task {
            let failure = await google.respond(to: event, choice: choice, calendar: CalendarModel.shared.calendar) {
                CalendarModel.shared.invalidate()
            }
            busy = false
            if let failure {
                error = failure
                try? await Task.sleep(for: .seconds(6))
                if error == failure { error = nil }
            } else {
                CalendarModel.shared.invalidate()
                MeetingsCoordinator.shared.dismissNotice(sourceId: sourceId)
            }
        }
    }
}

private struct ChoiceButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.Space.s)
                .frame(height: Theme.Control.compactHeight)
                .background(Capsule().fill(hovering ? Theme.surfaceHi : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
    }
}
