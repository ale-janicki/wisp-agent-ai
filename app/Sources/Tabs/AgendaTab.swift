import AppKit
import SwiftUI
import WispCore

struct AgendaTab: View {
    let profile: Profile

    private var agenda: AgendaModel { TabSources.shared.agenda }
    private var command: String? { profile.blocks?.agenda?.list }

    private var today: String {
        Date().formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(Locale(identifier: "pt_BR")))
    }

    var body: some View {
        TabCard(title: "Agenda", icon: PanelTab.agenda.icon, trailing: today) {
            list
        }
        .onAppear { if let command { agenda.refresh(command: command) } }
    }

    @ViewBuilder
    private var list: some View {
        switch agenda.state {
        case .loading:
            SkeletonRows(count: 3)
        case .failed(let message):
            TabMessage(text: message)
        case .loaded(let events) where events.isEmpty:
            TabMessage(text: "Nada na agenda hoje")
        case .loaded(let events):
            TimelineView(.everyMinute) { context in
                let markers = AgendaList.markers(events, now: context.date)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(events) { event in
                            AgendaRow(event: event, marker: markers[event.id], past: Self.isPast(event, now: context.date))
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private static func isPast(_ event: AgendaEvent, now: Date) -> Bool {
        guard let start = event.start else { return false }
        return (event.end ?? start) <= now
    }
}

private struct AgendaRow: View {
    let event: AgendaEvent
    let marker: AgendaList.Marker?
    let past: Bool

    private var caption: String {
        [event.calendar, event.location].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .trailing, spacing: 1) {
                if let start = event.start {
                    Text(Self.time(start))
                        .font(Theme.Font.captionMono)
                        .foregroundStyle(Theme.textPrimary)
                    if let end = event.end {
                        Text(Self.time(end))
                            .font(Theme.Font.captionMono)
                            .foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    Text("dia todo")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 44, alignment: .trailing)

            RoundedRectangle(cornerRadius: 1.5)
                .fill(marker == .now ? Theme.accent : Theme.stroke)
                .frame(width: 3, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(event.declined ? Theme.textTertiary : Theme.textPrimary)
                        .strikethrough(event.declined, color: Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let marker { MarkerCapsule(marker: marker) }
                }
                if !caption.isEmpty {
                    Text(caption)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: Theme.Space.xs)
            if let link = event.link {
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    Image(systemName: "video.fill")
                }
                .buttonStyle(CircleButtonStyle(kind: marker == .now ? .accent : .plain, size: 28))
                .help("Entrar na reunião: \(link.host() ?? link.absoluteString)")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: 48)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous)
                .fill(marker == .now ? Theme.accentFill.opacity(0.5) : .clear)
        }
        .opacity(past ? 0.5 : 1)
        .help(event.title)
    }

    private static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "pt_BR")))
    }
}

private struct MarkerCapsule: View {
    let marker: AgendaList.Marker

    var body: some View {
        Text(marker == .now ? "agora" : "próximo")
            .font(Theme.Font.caption)
            .foregroundStyle(marker == .now ? Theme.accentText : Theme.textSecondary)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(marker == .now ? Theme.accentFill : Theme.surfaceHi, in: Capsule())
    }
}
