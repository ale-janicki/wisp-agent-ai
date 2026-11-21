import Foundation

public enum AgendaCommand: Equatable, Sendable {
    case events(from: String?, to: String?, today: Bool, week: Bool, calendar: String?)
    case createEvent(title: String, start: String, end: String, location: String?, notes: String?, calendar: String?)
    case editEvent(id: String, title: String?, start: String?, end: String?, location: String?, notes: String?, calendar: String?,
                   series: Bool, confirmed: Bool)
    case deleteEvent(id: String, series: Bool, confirmed: Bool)
    case access(request: Bool)
    case reminders(pendingOnly: Bool, list: String?)
    case createReminder(title: String, when: String?, list: String?)
    case completeReminder(id: String)
    case calendars

    public static let usage = """
    uso: wisp agenda <comando>
      eventos [--de ISO] [--ate ISO] [--hoje] [--semana] [--calendario NOME]
      criar-evento --titulo T --inicio ISO --fim ISO [--local L] [--notas N] [--calendario NOME]
      editar-evento <id> [--titulo T] [--inicio ISO] [--fim ISO] [--local L] [--notas N] [--calendario NOME] [--serie] [--confirmo]
      apagar-evento <id> [--serie] [--confirmo]
      lembretes [--pendentes] [--lista NOME]
      criar-lembrete --titulo T [--quando ISO] [--lista NOME]
      concluir-lembrete <id>
      calendarios
      permissao [--pedir]
    --serie: em evento recorrente, mexe na ocorrência escolhida e nas próximas (esta e as próximas), não na série inteira.
    """

    public static func parse(_ arguments: [String]) throws -> AgendaCommand {
        guard let name = arguments.first else { throw AgendaError(usage) }
        var parser = Parser(Array(arguments.dropFirst()), command: name)
        switch name {
        case "eventos":
            let command = AgendaCommand.events(
                from: try parser.value("--de"), to: try parser.value("--ate"), today: parser.flag("--hoje"),
                week: parser.flag("--semana"), calendar: try parser.value("--calendario"))
            try parser.finish()
            return command
        case "criar-evento":
            let command = AgendaCommand.createEvent(
                title: try parser.required("--titulo"), start: try parser.required("--inicio"), end: try parser.required("--fim"),
                location: try parser.value("--local"), notes: try parser.value("--notas"), calendar: try parser.value("--calendario"))
            try parser.finish()
            return command
        case "editar-evento":
            let title = try parser.value("--titulo"), start = try parser.value("--inicio"), end = try parser.value("--fim")
            let location = try parser.value("--local"), notes = try parser.value("--notas"), calendar = try parser.value("--calendario")
            let series = parser.flag("--serie"), confirmed = parser.flag("--confirmo")
            let command = AgendaCommand.editEvent(id: try parser.positional(), title: title, start: start, end: end,
                                                  location: location, notes: notes, calendar: calendar, series: series,
                                                  confirmed: confirmed)
            try parser.finish()
            return command
        case "apagar-evento":
            let series = parser.flag("--serie"), confirmed = parser.flag("--confirmo")
            let command = AgendaCommand.deleteEvent(id: try parser.positional(), series: series, confirmed: confirmed)
            try parser.finish()
            return command
        case "lembretes":
            let command = AgendaCommand.reminders(pendingOnly: parser.flag("--pendentes"), list: try parser.value("--lista"))
            try parser.finish()
            return command
        case "criar-lembrete":
            let command = AgendaCommand.createReminder(
                title: try parser.required("--titulo"), when: try parser.value("--quando"), list: try parser.value("--lista"))
            try parser.finish()
            return command
        case "concluir-lembrete":
            let command = AgendaCommand.completeReminder(id: try parser.positional())
            try parser.finish()
            return command
        case "permissao":
            let command = AgendaCommand.access(request: parser.flag("--pedir"))
            try parser.finish()
            return command
        case "calendarios":
            try parser.finish()
            return .calendars
        default:
            throw AgendaError("comando desconhecido: \(name)\n\(usage)")
        }
    }

    private struct Parser {
        private var rest: [String]
        private let command: String

        init(_ rest: [String], command: String) {
            self.rest = rest
            self.command = command
        }

        mutating func flag(_ name: String) -> Bool {
            let before = rest.count
            rest.removeAll { $0 == name }
            return rest.count != before
        }

        mutating func value(_ name: String) throws -> String? {
            var found: String?
            var index = 0
            while index < rest.count {
                let word = rest[index]
                if word == name {
                    guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--") else {
                        throw AgendaError("\(command): \(name) precisa de um valor")
                    }
                    found = rest[index + 1]
                    rest.removeSubrange(index...(index + 1))
                } else if word.hasPrefix(name + "=") {
                    found = String(word.dropFirst(name.count + 1))
                    rest.remove(at: index)
                } else {
                    index += 1
                }
            }
            return found
        }

        mutating func required(_ name: String) throws -> String {
            guard let found = try value(name), !found.isEmpty else { throw AgendaError("\(command): falta \(name)") }
            return found
        }

        mutating func positional() throws -> String {
            guard let index = rest.firstIndex(where: { !$0.hasPrefix("--") }) else { throw AgendaError("\(command): falta o id") }
            return rest.remove(at: index)
        }

        func finish() throws {
            if let extra = rest.first { throw AgendaError("\(command): argumento inesperado \(extra)") }
        }
    }
}
