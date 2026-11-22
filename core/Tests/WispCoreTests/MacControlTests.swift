import Foundation
import Testing
@testable import WispCore

private final class FakeDriver: MacDriver, @unchecked Sendable {
    var trusted = true
    var asked = 0
    var elements: [MacElement] = []
    var focused = MacFocus(app: "Safari", element: MacElement(role: "AXTextField", title: "Endereço"))
    var calls: [String] = []

    func requestTrust() { asked += 1 }
    func tree(app: String?, max: Int, depth: Int) throws -> [MacElement] { elements }
    var expected: [MacElement] = []
    var blocks: [String?] = []
    var hits: [MacHit] = []
    func pressElement(app: String?, max: Int, depth: Int, at index: Int, expect: MacElement, block: String?) throws {
        calls.append("press \(index)")
        expected.append(expect)
        blocks.append(block)
    }
    func hit(x: Int, y: Int) -> MacHit? {
        hits.first { $0.element.centerX == x && $0.element.centerY == y }
            ?? elements.first { $0.centerX == x && $0.centerY == y }.map { MacHit(element: $0, app: "Mail") }
    }
    func clickPoint(x: Int, y: Int) throws { calls.append("point \(x),\(y)") }
    func focus(app: String?) throws -> MacFocus { focused }
    func type(_ text: String, app: String?) throws { calls.append("type \(text)") }
    func key(_ combo: MacKeyCombo, app: String?) throws { calls.append("key \(combo.keyCode)") }
    func scroll(dx: Int, dy: Int, app: String?) throws { calls.append("scroll \(dx),\(dy)") }
    func menuItem(path: [String], app: String?, press: Bool) throws -> MacElement {
        calls.append("menu \(path.joined(separator: ">")) \(press)")
        return MacElement(role: "AXMenuItem", title: path.last ?? "")
    }
    func apps() -> [MacApp] { [MacApp(name: "Safari", bundleID: "com.apple.Safari", pid: 7, active: true, hidden: false)] }
    func windows(app: String?) throws -> [MacWindow] { [] }
    func activate(app: String) throws { calls.append("activate \(app)") }
    func hide(app: String) throws { calls.append("hide \(app)") }
    func quit(app: String) throws { calls.append("quit \(app)") }
}

@Suite struct MacControlTests {
    private let sendPattern = "\\b(send|enviar)\\b"

    private func service(_ driver: FakeDriver) -> MacControlService { MacControlService(driver: driver) }

    @Test func keyCombosParse() throws {
        let combo = try MacKeyCombo.parse("cmd+shift+4")
        #expect(combo == MacKeyCombo(keyCode: 21, command: true, shift: true, option: false, control: false, function: false))
        #expect(try MacKeyCombo.parse("return").keyCode == 36)
        #expect(try MacKeyCombo.parse("alt+f4").option)
        #expect(throws: MacError.self) { try MacKeyCombo.parse("cmd+") }
        #expect(throws: MacError.self) { try MacKeyCombo.parse("hyper+a") }
        #expect(throws: MacError.self) { try MacKeyCombo.parse("cmd+nada") }
    }

    @Test func pointsAndMenuPathsParse() throws {
        #expect(try MacPoint.parse("120, 45").x == 120)
        #expect(throws: MacError.self) { try MacPoint.parse("12") }
        #expect(try MacMenuPath.parse("Arquivo > Exportar > PDF") == ["Arquivo", "Exportar", "PDF"])
        #expect(throws: MacError.self) { try MacMenuPath.parse("Arquivo") }
    }

    @Test func commandsParseAndRejectBadInput() throws {
        #expect(try MacCommand.parse(["rolar", "--direcao", "baixo", "--quantidade", "3"]) == .scroll(dx: 0, dy: -3, app: nil))
        #expect(try MacCommand.parse(["clicar", "--ponto", "10,20", "--app", "Mail"]) == .click(.point(x: 10, y: 20), app: "Mail", block: nil, resolveOnly: false))
        #expect(throws: MacError.self) { try MacCommand.parse(["clicar"]) }
        #expect(throws: MacError.self) { try MacCommand.parse(["digitar"]) }
        #expect(throws: MacError.self) { try MacCommand.parse(["ativar"]) }
        #expect(throws: MacError.self) { try MacCommand.parse(["arvore", "--max"]) }
        #expect(throws: MacError.self) { try MacCommand.parse(["explodir"]) }
    }

    @Test func missingAccessibilityFailsFastWithTheSettingsPath() {
        let driver = FakeDriver()
        driver.trusted = false
        for arguments in [["arvore"], ["foco"], ["clicar", "--titulo", "OK"], ["digitar", "oi"], ["tecla", "cmd+c"], ["rolar", "--dy", "3"], ["menu", "A > B"]] {
            let outcome = service(driver).run(arguments: arguments)
            #expect(outcome.exitCode == MacError.permission, "\(arguments)")
            #expect(outcome.stderr.contains("Controle do Mac"))
        }
        #expect(driver.calls.isEmpty)
    }

    @Test func permissionReportsWithoutAskingUnlessAsked() {
        let driver = FakeDriver()
        driver.trusted = false
        #expect(service(driver).run(arguments: ["permissao"]).stdout == #"{"acessibilidade":"needed"}"#)
        #expect(driver.asked == 0)
        _ = service(driver).run(arguments: ["permissao", "--pedir"])
        #expect(driver.asked == 1)
        driver.trusted = true
        #expect(service(driver).run(arguments: ["permissao", "--pedir"]).stdout == #"{"acessibilidade":"granted"}"#)
        #expect(driver.asked == 1)
    }

    @Test func typingIntoAPasswordFieldIsRefusedAndNothingIsTyped() {
        let driver = FakeDriver()
        driver.focused = MacFocus(app: "Safari", element: MacElement(role: "AXTextField", subrole: "AXSecureTextField", title: "Senha"))
        let outcome = service(driver).run(arguments: ["digitar", "hunter2"])
        #expect(outcome.exitCode == MacError.refused)
        #expect(outcome.stderr == MacRefusal.secureField)
        #expect(driver.calls.isEmpty)
        driver.focused = MacFocus(app: "Safari", element: MacElement(role: "AXTextField", title: "Busca"))
        #expect(service(driver).run(arguments: ["digitar", "oi"]).exitCode == 0)
        #expect(driver.calls == ["type oi"])
    }

    @Test func passwordValuesNeverAppearInTheTree() {
        let field = MacElement(role: "AXTextField", subrole: "AXSecureTextField", title: "Senha", value: "hunter2", x: 1, y: 2, width: 3, height: 4)
        let line = MacTree.line(field, index: 3)
        #expect(line == "[3] AXTextField/AXSecureTextField \"Senha\" value=<oculto> @1,2 3x4")
    }

    @Test func treeIsCompactAndIndented() {
        let elements = [
            MacElement(role: "AXWindow", title: "Mail", width: 800, height: 600),
            MacElement(role: "AXButton", title: "Enviar", width: 40, height: 20, depth: 1),
            MacElement(role: "AXTextArea", value: String(repeating: "a", count: 200), depth: 1),
        ]
        let lines = MacTree.render(elements).split(separator: "\n")
        #expect(lines[0] == "[0] AXWindow \"Mail\" @0,0 800x600")
        #expect(lines[1] == " [1] AXButton \"Enviar\" @0,0 40x20")
        #expect(lines[2].count < 120 && lines[2].contains("…"))
    }

    @Test func clickMatchesByTitleRoleAndIndexAndPressesTheRightElement() throws {
        let driver = FakeDriver()
        driver.elements = [
            MacElement(role: "AXWindow", title: "Janela"),
            MacElement(role: "AXButton", title: "Salvar como…"),
            MacElement(role: "AXButton", title: "Salvar"),
            MacElement(role: "AXStaticText", title: "Salvar"),
        ]
        let outcome = service(driver).run(arguments: ["clicar", "--titulo", "salvar", "--papel", "AXButton"])
        #expect(outcome.exitCode == 0)
        #expect(driver.calls == ["press 2"], "the exact title wins over a partial one")
        driver.calls = []
        _ = service(driver).run(arguments: ["clicar", "--titulo", "salvar", "--papel", "AXButton", "--indice", "1"])
        #expect(driver.calls == ["press 1"])
        driver.calls = []
        #expect(service(driver).run(arguments: ["clicar", "--titulo", "inexistente"]).exitCode == 1)
        #expect(driver.calls.isEmpty)
    }

    @Test func sendButtonsAreBlockedWhenTheCallerAsksForIt() {
        let driver = FakeDriver()
        driver.elements = [MacElement(role: "AXButton", title: "Enviar", x: 10, y: 10, width: 20, height: 20)]
        let blocked = service(driver).run(arguments: ["clicar", "--titulo", "Enviar", "--bloquear", sendPattern])
        #expect(blocked.exitCode == MacError.blocked)
        #expect(blocked.stderr.contains("mac_send"))
        let byPoint = service(driver).run(arguments: ["clicar", "--ponto", "20,20", "--bloquear", sendPattern])
        #expect(byPoint.exitCode == MacError.blocked)
        #expect(driver.calls.isEmpty)
        let allowed = service(driver).run(arguments: ["clicar", "--regex", sendPattern, "--papel", "AXButton"])
        #expect(allowed.exitCode == 0)
        #expect(driver.calls == ["press 0"])
    }

    @Test func pointClicksCheckTheElementItsAncestorsAndItsOwnApp() {
        let driver = FakeDriver()
        let button = MacElement(role: "AXImage", title: "", x: 10, y: 10, width: 20, height: 20)
        let parent = MacElement(role: "AXGroup", identifier: "sendButton")
        driver.hits = [MacHit(element: button, ancestors: [MacElement(role: "AXGroup"), parent], app: "Mail")]
        let blocked = service(driver).run(arguments: ["clicar", "--ponto", "20,20", "--bloquear", "\\bsend", "--app", "Safari"])
        #expect(blocked.exitCode == MacError.blocked)
        #expect(driver.calls.isEmpty)
        let report = service(driver).run(arguments: ["clicar", "--ponto", "20,20", "--resolver"])
        #expect(report.stdout.contains("\"app\":\"Mail\""))
        #expect(driver.calls.isEmpty)
        driver.hits = [MacHit(element: button, ancestors: [MacElement(role: "AXGroup"), MacElement(role: "AXGroup"), MacElement(role: "AXGroup"), parent], app: "Mail")]
        #expect(service(driver).run(arguments: ["clicar", "--ponto", "20,20", "--bloquear", "\\bsend"]).exitCode == 0, "only 3 ancestors are read")
    }

    @Test func helpAndIdentifierCountAsSendLabelsAndAncestorsFollowTheDepth() {
        let pattern = "\\b(send|enviar)\\b"
        #expect(MacSafety.blocks(MacElement(role: "AXButton", help: "Send message"), pattern: pattern))
        #expect(MacSafety.blocks(MacElement(role: "AXButton", identifier: "Enviar"), pattern: pattern))
        let tree = [MacElement(role: "AXWindow"), MacElement(role: "AXGroup", title: "Enviar", depth: 1),
                    MacElement(role: "AXGroup", depth: 2), MacElement(role: "AXImage", depth: 3), MacElement(role: "AXButton", depth: 1)]
        #expect(MacSafety.ancestors(of: 3, in: tree).map(\.role) == ["AXGroup", "AXGroup", "AXWindow"])
        #expect(MacSafety.blocks(tree[3], ancestors: MacSafety.ancestors(of: 3, in: tree), pattern: pattern))
        #expect(!MacSafety.blocks(tree[4], ancestors: MacSafety.ancestors(of: 4, in: tree), pattern: pattern), "a sibling branch is not an ancestor")
    }

    @Test func theElementAboutToBePressedIsHandedToTheDriverForARecheck() {
        let driver = FakeDriver()
        driver.elements = [MacElement(role: "AXWindow"), MacElement(role: "AXButton", title: "Salvar", depth: 1)]
        _ = service(driver).run(arguments: ["clicar", "--titulo", "Salvar", "--bloquear", "x"])
        #expect(driver.expected.map(\.title) == ["Salvar"] && driver.blocks == ["x"])
    }

    @Test func keysAndTypingFailClosedOnPasswordOrUnreadableFocus() {
        let driver = FakeDriver()
        driver.focused = MacFocus(app: "Safari", element: MacElement(role: "AXTextField", subrole: "AXSecureTextField"))
        for arguments in [["tecla", "cmd+v"], ["tecla", "return"], ["digitar", "x"]] {
            #expect(service(driver).run(arguments: arguments).stderr == MacRefusal.secureField, "\(arguments)")
        }
        driver.focused = MacFocus(app: "Safari", element: nil)
        for arguments in [["tecla", "cmd+v"], ["digitar", "x"]] {
            let outcome = service(driver).run(arguments: arguments)
            #expect(outcome.exitCode == MacError.refused && outcome.stderr == MacRefusal.unreadableFocus, "\(arguments)")
        }
        #expect(driver.calls.isEmpty)
    }

    @Test func focusReportCarriesTheDocumentAndWindowForBrowsers() {
        let driver = FakeDriver()
        driver.focused = MacFocus(app: "Safari", element: MacElement(role: "AXTextField"), document: "https://mail.google.com/x", window: "Entrada")
        let out = service(driver).run(arguments: ["foco"]).stdout
        #expect(out.contains("\"documento\":\"https://mail.google.com/x\"") && out.contains("\"janela\":\"Entrada\""))
    }

    @Test func resolveOnlyNeverPresses() {
        let driver = FakeDriver()
        driver.elements = [MacElement(role: "AXButton", title: "OK")]
        #expect(service(driver).run(arguments: ["clicar", "--titulo", "OK", "--resolver"]).exitCode == 0)
        #expect(driver.calls.isEmpty)
    }

    @Test func menuKeyAndScrollReachTheDriver() {
        let driver = FakeDriver()
        _ = service(driver).run(arguments: ["menu", "Arquivo > Salvar"])
        _ = service(driver).run(arguments: ["tecla", "cmd+s"])
        _ = service(driver).run(arguments: ["rolar", "--direcao", "cima", "--quantidade", "4"])
        #expect(driver.calls == ["menu Arquivo>Salvar true", "key 1", "scroll 0,4"])
    }

    @Test func elementMatchingIsAccentAndCaseInsensitive() {
        let elements = [MacElement(role: "AXButton", title: "Configurações"), MacElement(role: "AXButton", title: "Cancelar")]
        #expect(MacMatch.indexes(in: elements, title: "CONFIGURACOES", regex: nil, role: nil) == [0])
        #expect(MacMatch.indexes(in: elements, title: nil, regex: "^canc", role: "AXButton") == [1])
        #expect(MacMatch.indexes(in: elements, title: nil, regex: "(", role: nil).isEmpty)
    }

    @Test func theSelfTestParsesWithoutTouchingTheMac() throws {
        #expect(try MacSelfTest.run() == "selftest ok")
        #expect(service(FakeDriver()).run(arguments: ["selftest"]).stdout == "selftest ok")
    }

    @Test func composeReadsTheComposerValueAndTheToFieldNotTheWholeTree() {
        let tree = [
            MacElement(role: "AXWindow", title: "Nova mensagem"),
            MacElement(role: "AXStaticText", title: "Para:", depth: 1),
            MacElement(role: "AXTokenField", value: "ana@x.com, Bia <bia@x.com>; ana@x.com", depth: 1),
            MacElement(role: "AXStaticText", title: "Assunto:", depth: 1),
            MacElement(role: "AXTextField", value: "Oi", depth: 1),
            MacElement(role: "AXStaticText", value: "texto solto que não é o corpo", depth: 1),
        ]
        let body = MacElement(role: "AXTextArea", value: "Ele disse \"oi\"\n" + String(repeating: "x", count: 25_000))
        let compose = MacCompose.extract(elements: tree, focused: body, window: "Nova mensagem")
        #expect(compose.recipients == ["ana@x.com", "Bia <bia@x.com>"])
        #expect(compose.subject == "Oi")
        #expect(compose.body.hasPrefix("Ele disse \"oi\"\n") && compose.body.count == 25_000 + 15)
        #expect(MacCompose.extract(elements: tree, focused: MacElement(role: "AXButton", value: "x"), window: "").body == "")
        let secure = MacElement(role: "AXTextField", subrole: "AXSecureTextField", value: "senha")
        #expect(MacCompose.extract(elements: tree, focused: secure, window: "").body == "")
    }

    @Test func composeCommandReturnsTheRawValuesWithQuotesAndNoTruncation() throws {
        let driver = FakeDriver()
        driver.elements = [MacElement(role: "AXWindow"), MacElement(role: "AXStaticText", title: "To:", depth: 1), MacElement(role: "AXTextField", value: "ana", depth: 1)]
        driver.focused = MacFocus(app: "Mail", element: MacElement(role: "AXTextArea", value: "a \"b\" " + String(repeating: "z", count: 30_000)), window: "W")
        let out = service(driver).run(arguments: ["composicao"]).stdout
        let object = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect((object["corpo"] as? String)?.count == 6 + 30_000)
        #expect(object["destinatarios"] as? [String] == ["ana"])
    }

    @Test func fullTreeKeepsQuotesAndTheWholeValue() {
        let long = "q\"" + String(repeating: "a", count: 21_000)
        let line = MacTree.line(MacElement(role: "AXTextArea", value: long), index: 0, full: true)
        #expect(line.contains("\\\"") && line.count > 21_000)
    }

    @Test func theHelperActsOnlyWithTheCallersNonce() {
        let driver = FakeDriver()
        let nonce = String(repeating: "ab", count: 16)
        #expect(service(driver).run(arguments: ["tecla", "cmd+t"], environment: [:]).exitCode == MacError.refused)
        #expect(service(driver).run(arguments: ["tecla", "cmd+t"], environment: [MacCaller.variable: "curto"]).exitCode == MacError.refused)
        #expect(service(driver).run(arguments: ["tecla", "cmd+t"], environment: [MacCaller.variable: String(repeating: "z", count: 32)]).exitCode == MacError.refused)
        #expect(driver.calls.isEmpty)
        #expect(service(driver).run(arguments: ["permissao"], environment: [:]).exitCode == 0)
        #expect(service(driver).run(arguments: ["selftest"], environment: [:]).stdout == "selftest ok")
        #expect(service(driver).run(arguments: ["tecla", "cmd+t"], environment: [MacCaller.variable: nonce]).exitCode == 0)
    }
}
