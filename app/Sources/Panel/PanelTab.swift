import Foundation
import WispCore

enum PanelTab: String, CaseIterable, Identifiable {
    case home, conversation, brain, tasks, agenda, meetings, music, clipboard, terminal, myMac, settings

    var id: Self { self }

    static func decoded(_ raw: String) -> PanelTab? {
        switch raw {
        case "memory": .brain
        case "routines": .settings
        default: PanelTab(rawValue: raw)
        }
    }

    /// Tabs that draw their own list column next to the content. In every mode (notch panel, window, fullscreen) the main
    /// sidebar folds into an icon rail on these (it floats open on hover), so the two columns do not stack.
    var hasSecondaryColumn: Bool {
        switch self {
        case .conversation, .meetings, .terminal: true
        default: false
        }
    }

    static let order: [PanelTab] = [.home, .conversation, .brain, .tasks, .agenda, .meetings, .music, .clipboard, .terminal, .myMac]

    static func nav(for profile: Profile) -> [PanelTab] {
        order.filter { $0.isAvailable(in: profile) }
    }

    func isAvailable(in profile: Profile) -> Bool {
        switch self {
        case .tasks: profile.blocks?.tasks?.file.isPresent ?? false
        case .brain: profile.blocks?.memory?.root.isPresent ?? false
        default: true
        }
    }

    var title: String {
        switch self {
        case .home: "Início"
        case .conversation: "Conversa"
        case .tasks: "Tarefas"
        case .agenda: "Agenda"
        case .meetings: "Reuniões"
        case .brain: "Brain"
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
        case .agenda: "calendar"
        case .meetings: "waveform"
        case .brain: "brain.head.profile"
        case .music: "music.note"
        case .clipboard: "doc.on.clipboard.fill"
        case .terminal: "terminal"
        case .myMac: "laptopcomputer"
        case .settings: "gearshape.fill"
        }
    }
}

extension Profile {
    var hasRoutines: Bool {
        guard let routines = blocks?.routines, routines.status.isPresent else { return false }
        return routines.registry.isPresent || !(routines.prefixes ?? []).isEmpty
    }
}

private extension Optional where Wrapped == String {
    var isPresent: Bool {
        guard let self else { return false }
        return !self.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
