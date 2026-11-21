import Foundation

public enum MacSelector: Equatable, Sendable {
    case query(title: String?, regex: String?, role: String?, index: Int)
    case point(x: Int, y: Int)
}

public enum MacCommand: Equatable, Sendable {
    case permission(ask: Bool)
    case tree(app: String?, max: Int, depth: Int, full: Bool)
    case focus(app: String?)
    case click(MacSelector, app: String?, block: String?, resolveOnly: Bool)
    case type(text: String, app: String?)
    case key(MacKeyCombo, app: String?)
    case scroll(dx: Int, dy: Int, app: String?)
    case menu(path: [String], app: String?, resolveOnly: Bool)
    case apps
    case windows(app: String?)
    case activate(app: String)
    case hide(app: String)
    case quit(app: String)
    case selfTest

    static let valueOptions: Set<String> = [
        "--app", "--max", "--profundidade", "--titulo", "--regex", "--papel", "--indice", "--ponto", "--bloquear", "--dx", "--dy",
        "--direcao", "--quantidade",
    ]
    static let flagOptions: Set<String> = ["--pedir", "--completo", "--resolver"]

    public static func parse(_ arguments: [String]) throws -> MacCommand {
        guard let name = arguments.first else { throw MacError(MacCommand.usageText, exitCode: MacError.usage) }
        var positional: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var index = 1
        while index < arguments.count {
            let word = arguments[index]
            if valueOptions.contains(word) {
                guard index + 1 < arguments.count else { throw MacError("\(word) precisa de um valor", exitCode: MacError.usage) }
                options[word] = arguments[index + 1]
                index += 2
            } else if flagOptions.contains(word) {
                flags.insert(word)
                index += 1
            } else if word.hasPrefix("--") {
                throw MacError("opção desconhecida: \(word)", exitCode: MacError.usage)
            } else {
                positional.append(word)
                index += 1
            }
        }
        let app = options["--app"]
        func number(_ key: String, _ fallback: Int) throws -> Int {
            guard let raw = options[key] else { return fallback }
            guard let value = Int(raw) else { throw MacError("\(key) precisa de um número: \(raw)", exitCode: MacError.usage) }
            return value
        }
        func one(_ what: String) throws -> String {
            guard positional.count == 1 else { throw MacError("\(name): informe \(what)", exitCode: MacError.usage) }
            return positional[0]
        }
        switch name {
        case "permissao": return .permission(ask: flags.contains("--pedir"))
        case "arvore":
            return .tree(app: app, max: min(max(try number("--max", MacTree.defaultMax), 1), 2000),
                         depth: min(max(try number("--profundidade", MacTree.defaultDepth), 1), 20), full: flags.contains("--completo"))
        case "foco": return .focus(app: app)
        case "clicar":
            let selector: MacSelector
            if let raw = options["--ponto"] {
                let point = try MacPoint.parse(raw)
                selector = .point(x: point.x, y: point.y)
            } else {
                guard options["--titulo"] != nil || options["--regex"] != nil || options["--papel"] != nil else {
                    throw MacError("clicar: informe --titulo, --regex, --papel ou --ponto", exitCode: MacError.usage)
                }
                selector = .query(title: options["--titulo"], regex: options["--regex"], role: options["--papel"],
                                  index: max(try number("--indice", 0), 0))
            }
            return .click(selector, app: app, block: options["--bloquear"], resolveOnly: flags.contains("--resolver"))
        case "digitar": return .type(text: try one("o texto"), app: app)
        case "tecla": return .key(try MacKeyCombo.parse(try one("a tecla, como cmd+shift+4")), app: app)
        case "rolar":
            var dx = try number("--dx", 0), dy = try number("--dy", 0)
            if let direction = options["--direcao"] {
                let amount = try number("--quantidade", 5)
                switch direction {
                case "cima": dy = amount
                case "baixo": dy = -amount
                case "esquerda": dx = amount
                case "direita": dx = -amount
                default: throw MacError("--direcao: use cima, baixo, esquerda ou direita", exitCode: MacError.usage)
                }
            }
            guard dx != 0 || dy != 0 else { throw MacError("rolar: informe --direcao ou --dx/--dy", exitCode: MacError.usage) }
            return .scroll(dx: min(max(dx, -200), 200), dy: min(max(dy, -200), 200), app: app)
        case "menu": return .menu(path: try MacMenuPath.parse(try one("o caminho do menu")), app: app, resolveOnly: flags.contains("--resolver"))
        case "apps": return .apps
        case "janelas": return .windows(app: app)
        case "ativar": return .activate(app: try required(app, name))
        case "esconder": return .hide(app: try required(app, name))
        case "sair": return .quit(app: try required(app, name))
        case "selftest": return .selfTest
        default: throw MacError("comando desconhecido: \(name)\n" + usageText, exitCode: MacError.usage)
        }
    }

    private static func required(_ app: String?, _ command: String) throws -> String {
        guard let app, !app.isEmpty else { throw MacError("\(command): informe --app", exitCode: MacError.usage) }
        return app
    }

    public static let usageText = """
    wisp-mac <comando>: permissao [--pedir] | arvore [--app N] [--max N] [--profundidade N] [--completo] | foco [--app N] | \
    clicar (--titulo T | --regex R | --papel P | --ponto x,y) [--indice N] [--app N] [--bloquear R] [--resolver] | digitar <texto> [--app N] | \
    tecla <cmd+shift+4> [--app N] | rolar (--direcao cima|baixo|esquerda|direita [--quantidade N] | --dx N --dy N) | \
    menu "A > B" [--app N] [--resolver] | apps | janelas [--app N] | ativar|esconder|sair --app N | selftest
    """
}
