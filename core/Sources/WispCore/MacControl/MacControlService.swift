import Foundation

public struct MacApp: Equatable, Sendable {
    public let name: String
    public let bundleID: String
    public let pid: Int
    public let active: Bool
    public let hidden: Bool

    public init(name: String, bundleID: String, pid: Int, active: Bool, hidden: Bool) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
        self.active = active
        self.hidden = hidden
    }
}

public struct MacWindow: Equatable, Sendable {
    public let id: Int
    public let app: String
    public let title: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(id: Int, app: String, title: String, x: Int, y: Int, width: Int, height: Int) {
        self.id = id
        self.app = app
        self.title = title
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct MacFocus: Equatable, Sendable {
    public let app: String
    public let element: MacElement?
    public let document: String
    public let window: String
    public let bundle: String

    public init(app: String, element: MacElement?, document: String = "", window: String = "", bundle: String = "") {
        self.app = app
        self.element = element
        self.document = document
        self.window = window
        self.bundle = bundle
    }
}

public struct MacHit: Equatable, Sendable {
    public let element: MacElement
    public let ancestors: [MacElement]
    public let app: String

    public init(element: MacElement, ancestors: [MacElement] = [], app: String = "") {
        self.element = element
        self.ancestors = ancestors
        self.app = app
    }
}

public protocol MacDriver {
    var trusted: Bool { get }
    func requestTrust()
    func tree(app: String?, max: Int, depth: Int) throws -> [MacElement]
    func pressElement(app: String?, max: Int, depth: Int, at index: Int, expect: MacElement, block: String?) throws
    func hit(x: Int, y: Int) -> MacHit?
    func clickPoint(x: Int, y: Int) throws
    func focus(app: String?) throws -> MacFocus
    func type(_ text: String, app: String?) throws
    func key(_ combo: MacKeyCombo, app: String?) throws
    func scroll(dx: Int, dy: Int, app: String?) throws
    func menuItem(path: [String], app: String?, press: Bool, exact: Bool, block: String?, expect: String?) throws -> MacElement
    func apps() -> [MacApp]
    func windows(app: String?) throws -> [MacWindow]
    func activate(app: String) throws
    func hide(app: String) throws
    func quit(app: String) throws
}

public struct MacControlService {
    public static let composeMax = 1500
    public static let composeDepth = 20

    private let driver: any MacDriver

    public init(driver: any MacDriver) {
        self.driver = driver
    }

    public func run(arguments: [String], authorize: (() -> Bool)? = nil) -> MacOutcome {
        if let authorize, let first = arguments.first, !MacCaller.freeCommands.contains(first), !authorize() {
            return MacOutcome(stderr: MacCaller.refusal, exitCode: MacError.refused)
        }
        do {
            let command = try MacCommand.parse(arguments)
            return MacOutcome(stdout: try execute(command))
        } catch let error as MacError {
            return MacOutcome(stderr: error.message, exitCode: error.exitCode)
        } catch {
            return MacOutcome(stderr: error.localizedDescription, exitCode: 1)
        }
    }

    private func needAccessibility() throws {
        guard driver.trusted else { throw MacError.noAccessibility }
    }

    private func execute(_ command: MacCommand) throws -> String {
        switch command {
        case .permission(let ask):
            if ask, !driver.trusted { driver.requestTrust() }
            return try json(["acessibilidade": driver.trusted ? "granted" : "needed"])
        case .selfTest:
            return try MacSelfTest.run()
        case .apps:
            return try json(driver.apps().map { ["nome": $0.name, "bundle": $0.bundleID, "pid": $0.pid, "ativo": $0.active, "oculto": $0.hidden] as [String: Any] })
        case .activate(let app):
            try driver.activate(app: app)
            return "ok"
        case .hide(let app):
            try driver.hide(app: app)
            return "ok"
        case .quit(let app):
            try driver.quit(app: app)
            return "ok"
        case .windows(let app):
            return try json(try driver.windows(app: app).map {
                ["id": $0.id, "app": $0.app, "titulo": $0.title, "x": $0.x, "y": $0.y, "largura": $0.width, "altura": $0.height] as [String: Any]
            })
        case .tree(let app, let max, let depth, let full):
            try needAccessibility()
            let elements = try driver.tree(app: app, max: max, depth: depth)
            return elements.isEmpty ? "(a janela não tem elementos legíveis)" : MacTree.render(elements, full: full)
        case .focus(let app):
            try needAccessibility()
            let focus = try driver.focus(app: app)
            return try json(focusReport(focus))
        case .compose(let app):
            try needAccessibility()
            let focus = try driver.focus(app: app)
            let elements = try driver.tree(app: app, max: Self.composeMax, depth: Self.composeDepth)
            guard elements.count < Self.composeMax else { throw MacError(MacRefusal.windowTooBig, exitCode: MacError.refused) }
            let compose = MacCompose.extract(elements: elements, window: focus.window)
            return try json(["app": focus.app, "corpo": compose.body, "destinatarios": compose.recipients, "cc": compose.cc, "bcc": compose.bcc,
                             "assunto": compose.subject, "janela": compose.window])
        case .sendCompose(let app, let pattern, let expected):
            try needAccessibility()
            return try sendCompose(app: app, pattern: pattern, expected: expected)
        case .click(let selector, let app, let block, let strict, let resolveOnly):
            try needAccessibility()
            return try click(selector, app: app, block: block, strict: strict, resolveOnly: resolveOnly)
        case .type(let text, let app):
            try needAccessibility()
            try requireWritableFocus(app)
            try driver.type(text, app: app)
            return "ok"
        case .key(let combo, let app):
            try needAccessibility()
            try requireWritableFocus(app)
            try driver.key(combo, app: app)
            return "ok"
        case .scroll(let dx, let dy, let app):
            try needAccessibility()
            try driver.scroll(dx: dx, dy: dy, app: app)
            return "ok"
        case .menu(let path, let app, let block, let exact, let resolveOnly):
            try needAccessibility()
            let found = try driver.menuItem(path: path, app: app, press: false, exact: exact, block: nil, expect: nil)
            if MacSafety.blocks(found, pattern: block) { throw blocked(found) }
            if !resolveOnly { _ = try driver.menuItem(path: path, app: app, press: true, exact: exact, block: block, expect: found.title) }
            return try json(["menu": path.joined(separator: " > "), "titulo": found.label])
        }
    }

    private func requireWritableFocus(_ app: String?) throws {
        guard let element = try driver.focus(app: app).element else {
            throw MacError(MacRefusal.unreadableFocus, exitCode: MacError.refused)
        }
        if element.isSecure { throw MacError(MacRefusal.secureField, exitCode: MacError.refused) }
    }

    private func sendCompose(app: String?, pattern: String, expected: String) throws -> String {
        guard let data = expected.data(using: .utf8), let wanted = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MacError("enviar-janela: --esperado não é um JSON válido", exitCode: MacError.usage)
        }
        let focus = try driver.focus(app: app)
        let elements = try driver.tree(app: app, max: Self.composeMax, depth: Self.composeDepth)
        guard elements.count < Self.composeMax else { throw MacError(MacRefusal.windowTooBig, exitCode: MacError.refused) }
        let now = MacCompose.extract(elements: elements, window: focus.window)
        func list(_ key: String) -> [String] { ((wanted[key] as? [String]) ?? []).map(MacCompose.canon).sorted() }
        let same = MacCompose.canon(now.body) == (wanted["corpo"] as? String).map(MacCompose.canon)
            && now.recipients.map(MacCompose.canon).sorted() == list("destinatarios")
            && now.cc.map(MacCompose.canon).sorted() == list("cc")
            && MacCompose.canon(now.subject) == (wanted["assunto"] as? String).map(MacCompose.canon)
            && now.bcc.isEmpty && !now.body.isEmpty
        guard same else { throw MacError(MacRefusal.composeChanged, exitCode: MacError.refused) }
        let buttons = elements.indices.filter { elements[$0].role == "AXButton" && MacSafety.blocks(elements[$0], pattern: pattern) }
        guard buttons.count == 1, let index = buttons.first else { throw MacError(MacRefusal.noSingleSend, exitCode: MacError.refused) }
        try driver.pressElement(app: app, max: Self.composeMax, depth: Self.composeDepth, at: index, expect: elements[index], block: nil)
        return try json(["enviado": true, "botao": elements[index].label])
    }

    private func click(_ selector: MacSelector, app: String?, block: String?, strict: Bool, resolveOnly: Bool) throws -> String {
        switch selector {
        case .point(let x, let y):
            let found = driver.hit(x: x, y: y)
            if let found, MacSafety.blocks(found.element, ancestors: found.ancestors, pattern: block)
                || MacSafety.requiresCard(found.element, ancestors: found.ancestors, strict: strict) { throw blocked(found.element) }
            if !resolveOnly { try driver.clickPoint(x: x, y: y) }
            guard let found else { return try json(["ponto": "\(x),\(y)"]) }
            var report = elementReport(found.element)
            report["app"] = found.app
            report["ancestrais"] = found.ancestors.map(\.label)
            return try json(report)
        case .query(let title, let regex, let role, let index):
            let max = MacTree.defaultMax, depth = MacTree.defaultDepth
            let elements = try driver.tree(app: app, max: max, depth: depth)
            let found = MacMatch.indexes(in: elements, title: title, regex: regex, role: role)
            guard index < found.count else {
                throw MacError("não achei o elemento pedido na janela da frente (use arvore para ver os elementos)", exitCode: 1)
            }
            let target = elements[found[index]]
            let chain = MacSafety.ancestors(of: found[index], in: elements)
            if MacSafety.blocks(target, ancestors: chain, pattern: block) || MacSafety.requiresCard(target, ancestors: chain, strict: strict) {
                throw blocked(target)
            }
            if !resolveOnly { try driver.pressElement(app: app, max: max, depth: depth, at: found[index], expect: target, block: block) }
            return try json(elementReport(target))
        }
    }

    private func blocked(_ element: MacElement) -> MacError {
        MacError(MacRefusal.sendButton(element.label), exitCode: MacError.blocked)
    }

    private func elementReport(_ element: MacElement) -> [String: Any] {
        ["papel": element.role, "titulo": element.title, "descricao": element.detail, "x": element.centerX, "y": element.centerY]
    }

    private func focusReport(_ focus: MacFocus) -> [String: Any] {
        var report: [String: Any] = ["app": focus.app, "bundle": focus.bundle, "documento": focus.document, "janela": focus.window]
        guard let element = focus.element else { return report }
        report["papel"] = element.role
        report["subpapel"] = element.subrole
        report["titulo"] = element.title
        report["seguro"] = element.isSecure
        report["pressavel"] = element.pressable
        return report
    }

    private func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

public enum MacRefusal {
    public static let secureField = "recusei: o campo em foco é de senha, o Wisp nunca digita em campo de senha"
    public static let unreadableFocus = "recusei: não consegui ver qual campo está em foco, então não digito nada"
    public static let composeChanged = "recusei: a janela da mensagem mudou depois da aprovação (corpo, destinatários, cópias ou assunto) ou há cópia oculta"
    public static let windowTooBig = "recusei: a janela tem elementos demais para eu ler inteira (limite de 1500); feche abas ou painéis e tente de novo"
    public static let noSingleSend = "recusei: não achei exatamente um botão de enviar dentro da janela da mensagem"
    public static let focusChanged = "interrompi: o foco mudou de app ou virou campo de senha antes de digitar"

    public static func sendButton(_ label: String) -> String {
        "recusei: \"\(label)\" envia uma mensagem; o envio precisa da aprovação do usuário, use a ferramenta mac_send"
    }
}

public enum MacSelfTest {
    public static func run() throws -> String {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        let combo = try MacKeyCombo.parse("cmd+shift+4")
        check(combo.keyCode == 21 && combo.command && combo.shift && !combo.option, "tecla cmd+shift+4")
        check((try? MacKeyCombo.parse("cmd+")) == nil, "tecla incompleta")
        check((try? MacPoint.parse("10, 20")).map { $0.x == 10 && $0.y == 20 } ?? false, "ponto 10,20")
        check((try? MacMenuPath.parse("Arquivo > Salvar como…")) == ["Arquivo", "Salvar como…"], "caminho de menu")
        let secure = MacElement(role: "AXTextField", subrole: "AXSecureTextField", value: "segredo")
        check(secure.isSecure && MacTree.line(secure, index: 0).contains("<oculto>") && !MacTree.line(secure, index: 0).contains("segredo"), "campo de senha")
        let send = MacElement(role: "AXButton", title: "Enviar")
        check(MacSafety.blocks(send, pattern: "\\b(send|enviar)\\b"), "botão enviar")
        check(MacMatch.indexes(in: [send, MacElement(role: "AXButton", title: "Cancelar")], title: "enviar", regex: nil, role: "AXButton") == [0], "busca por título")
        check((try? MacCommand.parse(["clicar", "--titulo", "OK"])) != nil, "comando clicar")
        guard failures.isEmpty else { throw MacError("selftest falhou: " + failures.joined(separator: ", ")) }
        return "selftest ok"
    }
}
