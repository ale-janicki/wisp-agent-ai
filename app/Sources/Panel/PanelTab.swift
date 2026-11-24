import Foundation
import WispCore

enum PanelTab: String, CaseIterable, Identifiable {
    case home, conversation, brain, tasks, reminders, agenda, meetings, routines, music, clipboard, terminal, myMac, settings

    var id: Self { self }

    static func decoded(_ raw: String) -> PanelTab? {
        raw == "memory" ? .brain : PanelTab(rawValue: raw)
    }

    static let order: [PanelTab] = [.home, .conversation, .brain, .tasks, .reminders, .agenda, .meetings, .routines, .music, .clipboard, .terminal, .myMac]

    static func nav(for profile: Profile) -> [PanelTab] {
        order.filter { $0.isAvailable(in: profile) }
    }

    func isAvailable(in profile: Profile) -> Bool {
        switch self {
        case .tasks: profile.blocks?.tasks?.file.isPresent ?? false
        case .reminders: profile.blocks?.alerts?.list.isPresent ?? false
        case .brain: profile.blocks?.memory?.root.isPresent ?? false
        case .routines: (profile.blocks?.routines?.registry.isPresent ?? false) && (profile.blocks?.routines?.status.isPresent ?? false)
        default: true
        }
    }

    var title: String {
        switch self {
        case .home: "Início"
        case .conversation: "Conversa"
        case .tasks: "Tarefas"
        case .reminders: "Lembretes"
        case .agenda: "Agenda"
        case .meetings: "Reuniões"
        case .brain: "Brain"
        case .routines: "Rotinas"
        case .music: "Música"
        case .clipboard: "Copiados"
        case .terminal: "Terminal"
        case .myMac: "My Mac"
        case .settings: "Ajustes"
        }
    }

    var icon: String {
        switch self {
        case .home: "square.grid.2x2.fill"
        case .conversation: "bubble.left.and.bubble.right.fill"
        case .tasks: "checklist"
        case .reminders: "bell.fill"
        case .agenda: "calendar"
        case .meetings: "waveform"
        case .brain: "brain.head.profile"
        case .routines: "clock.arrow.circlepath"
        case .music: "music.note"
        case .clipboard: "doc.on.clipboard.fill"
        case .terminal: "terminal"
        case .myMac: "laptopcomputer"
        case .settings: "gearshape.fill"
        }
    }
}

private extension Optional where Wrapped == String {
    var isPresent: Bool {
        guard let self else { return false }
        return !self.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
