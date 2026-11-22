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
    var menuTitles: [String: String] = [:]
    func menuItem(path: [String], app: String?, press: Bool, exact: Bool, block: String?, expect: String?) throws -> MacElement {
        let last = path.last ?? ""
        let real = menuTitles[last] ?? last
        if exact, real != last { throw MacError("não achei o item de menu \"\(last)\"") }
        let item = MacElement(role: "AXMenuItem", title: real)
        if press {
            if MacSafety.blocks(item, pattern: block) { throw MacError(MacRefusal.sendButton(real), exitCode: MacError.blocked) }
            calls.append("menu \(path.joined(separator: ">")) \(real)")
        }
        return item
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
        #expect(try MacCommand.parse(["clicar", "--ponto", "10,20", "--app", "Mail"]) == .click(.point(x: 10, y: 20), app: "Mail", block: nil, strict: false, resolveOnly: false))
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
        #expect(driver.calls == ["menu Arquivo>Salvar Salvar", "key 1", "scroll 0,4"])
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

    private func composer(body: String = "corpo", extra: [MacElement] = []) -> [MacElement] {
        [
            MacElement(role: "AXWindow", title: "Nova mensagem", width: 800, height: 600),
            MacElement(role: "AXStaticText", title: "Para:", depth: 1),
            MacElement(role: "AXTokenField", value: "ana@x.com, Bia <bia@x.com>; ana@x.com", depth: 1),
            MacElement(role: "AXStaticText", title: "Assunto:", depth: 1),
            MacElement(role: "AXTextField", value: "Oi", depth: 1),
            MacElement(role: "AXTextArea", value: "pequeno", editable: true, width: 50, height: 20, depth: 1),
            MacElement(role: "AXTextArea", value: body, editable: true, width: 700, height: 400, depth: 1),
        ] + extra
    }

    @Test func composeTakesTheBodyFromTheLargestTextAreaAndTheFieldsFromTheirLabelsNotFromFocus() {
        let body = "Ele disse \"oi\"\n" + String(repeating: "x", count: 25_000)
        let compose = MacCompose.extract(elements: composer(body: body), window: "Nova mensagem")
        #expect(compose.recipients == ["ana@x.com", "Bia <bia@x.com>"])
        #expect(compose.subject == "Oi")
        #expect(compose.body == body)
        #expect(MacCompose.extract(elements: [MacElement(role: "AXButton", value: "x")], window: "").body == "")
        let secure = MacElement(role: "AXTextArea", subrole: "AXSecureTextField", value: "senha", editable: true, width: 900, height: 900)
        #expect(MacCompose.extract(elements: composer() + [secure], window: "").body == "corpo")
    }

    @Test func composeReadsCcAndBccFromTheirLabels() {
        let extra = [
            MacElement(role: "AXStaticText", title: "Cc:", depth: 1), MacElement(role: "AXTokenField", value: "carla@x.com", depth: 1),
            MacElement(role: "AXStaticText", title: "Bcc:", depth: 1), MacElement(role: "AXTokenField", value: "evil@y.com", depth: 1),
        ]
        let compose = MacCompose.extract(elements: composer(extra: extra), window: "")
        #expect(compose.cc == ["carla@x.com"] && compose.bcc == ["evil@y.com"])
        #expect(compose.recipients == ["ana@x.com", "Bia <bia@x.com>"])
        let portuguese = [MacElement(role: "AXStaticText", title: "Cco:", depth: 1), MacElement(role: "AXTextField", value: "x@y.com", depth: 1)]
        #expect(MacCompose.extract(elements: composer(extra: portuguese), window: "").bcc == ["x@y.com"])
    }

    @Test func composeCommandReturnsTheRawValuesWithQuotesNoTruncationAndTheCopies() throws {
        let driver = FakeDriver()
        let long = "a \"b\" " + String(repeating: "z", count: 30_000)
        driver.elements = composer(body: long, extra: [MacElement(role: "AXStaticText", title: "Bcc:", depth: 1), MacElement(role: "AXTextField", value: "evil@y.com", depth: 1)])
        driver.focused = MacFocus(app: "Mail", element: MacElement(role: "AXButton"), window: "W")
        let out = service(driver).run(arguments: ["composicao"]).stdout
        let object = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect((object["corpo"] as? String)?.count == 6 + 30_000, "the body does not depend on what has focus")
        #expect(object["destinatarios"] as? [String] == ["ana@x.com", "Bia <bia@x.com>"] && object["bcc"] as? [String] == ["evil@y.com"])
    }

    private func expected(_ driver: FakeDriver, body: String = "corpo") throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["corpo": body, "destinatarios": ["ana@x.com", "Bia <bia@x.com>"], "cc": [String](), "assunto": "Oi"])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func sendComposePressesTheOneSendButtonInTheSameProcessOnlyWhenNothingDiffers() throws {
        let driver = FakeDriver()
        driver.focused = MacFocus(app: "Mail", element: nil, window: "Nova")
        let send = MacElement(role: "AXButton", title: "Enviar", depth: 1)
        driver.elements = composer(extra: [send, MacElement(role: "AXButton", title: "Cancelar", depth: 1)])
        let args = ["enviar-janela", "--regex", "\\b(send|enviar)\\b", "--esperado"]
        #expect(service(driver).run(arguments: args + [try expected(driver)]).exitCode == 0)
        #expect(driver.calls == ["press 7"] && driver.expected.map(\.title) == ["Enviar"])
        for changed in [try expected(driver, body: "outro corpo"), "{}", "isso nao e json"] {
            driver.calls = []
            #expect(service(driver).run(arguments: args + [changed]).exitCode != 0)
            #expect(driver.calls.isEmpty)
        }
    }

    @Test func sendComposeRefusesBccCopiesThatDifferAndAmbiguousSendButtons() throws {
        let driver = FakeDriver()
        driver.focused = MacFocus(app: "Mail", element: nil, window: "Nova")
        let send = MacElement(role: "AXButton", title: "Send", depth: 1)
        let args = ["enviar-janela", "--regex", "\\b(send|enviar)\\b", "--esperado", try expected(driver)]
        driver.elements = composer(extra: [send, MacElement(role: "AXStaticText", title: "Bcc:", depth: 1), MacElement(role: "AXTextField", value: "evil@y.com", depth: 1)])
        #expect(service(driver).run(arguments: args).stderr == MacRefusal.composeChanged)
        driver.elements = composer(extra: [send, MacElement(role: "AXStaticText", title: "Cc:", depth: 1), MacElement(role: "AXTextField", value: "carla@x.com", depth: 1)])
        #expect(service(driver).run(arguments: args).stderr == MacRefusal.composeChanged, "cc must equal the approved cc")
        driver.elements = composer(extra: [send, MacElement(role: "AXButton", title: "Responder", depth: 1), MacElement(role: "AXButton", title: "Enviar", depth: 1)])
        #expect(service(driver).run(arguments: args).stderr == MacRefusal.noSingleSend)
        driver.elements = composer()
        #expect(service(driver).run(arguments: args).stderr == MacRefusal.noSingleSend)
        #expect(driver.calls.isEmpty)
    }

    @Test func aPartialMenuLabelIsResolvedToItsRealTitleAndBlockedByThatTitle() {
        let driver = FakeDriver()
        driver.menuTitles = ["Sen": "Send"]
        let blocked = service(driver).run(arguments: ["menu", "Message > Sen", "--bloquear", "\\b(send|enviar)\\b"])
        #expect(blocked.exitCode == MacError.blocked && blocked.stderr.contains("mac_send"))
        #expect(driver.calls.isEmpty)
        #expect(service(driver).run(arguments: ["menu", "Message > Sen", "--bloquear", "\\b(send|enviar)\\b", "--exato"]).exitCode == 1)
        #expect(service(driver).run(arguments: ["menu", "Arquivo > Imprimir", "--bloquear", "\\b(send|enviar)\\b"]).exitCode == 0)
        #expect(driver.calls == ["menu Arquivo>Imprimir Imprimir"])
        #expect(service(driver).run(arguments: ["menu", "Message > Sen", "--resolver"]).exitCode == 0)
    }

    @Test func sendLabelsInOtherLanguagesAndCamelOrSnakeIdentifiersAreRecognised() {
        let pattern = "\\b(send|enviar|senden|envoyer)\\b|发送|送信|Отправить|Invia|Wyślij|Verstuur|Répondre|Skicka"
        for title in ["发送", "送信", "Отправить", "Invia", "Wyślij", "Verstuur", "Répondre", "Skicka", "Senden", "Envoyer", "发送邮件"] {
            #expect(MacSafety.blocks(MacElement(role: "AXButton", title: title), pattern: pattern), "\(title)")
        }
        for identifier in ["send_button", "SendButton", "sendButton", "send-btn", "btn.send"] {
            #expect(MacSafety.blocks(MacElement(role: "AXButton", identifier: identifier), pattern: pattern), "\(identifier)")
        }
        for identifier in ["Sender", "resend", "Sentinel", "backButton"] {
            #expect(!MacSafety.blocks(MacElement(role: "AXButton", identifier: identifier), pattern: pattern), "\(identifier)")
        }
    }

    @Test func strictModeAsksForEveryPressableElementExceptTextFieldsScrollAreasAndTabs() {
        func card(_ role: String, label: String = "", pressable: Bool = true, ancestors: [MacElement] = []) -> Bool {
            MacSafety.requiresCard(MacElement(role: role, title: label, pressable: pressable), ancestors: ancestors, strict: true)
        }
        for role in ["AXButton", "AXMenuItem", "AXMenuButton"] { #expect(card(role, label: "Continuar", pressable: false), Comment(rawValue: role)) }
        for role in ["AXGroup", "AXLink", "AXStaticText", "AXRow", "AXCell", "AXMenuBarItem", "AXImage", "AXUnknown", "AXDisclosureTriangle"] {
            #expect(card(role, label: "x"), Comment(rawValue: role))
        }
        for role in ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXScrollArea", "AXScrollBar", "AXTab"] {
            #expect(!card(role), Comment(rawValue: role))
        }
        #expect(!card("AXRadioButton", ancestors: [MacElement(role: "AXTabGroup")]), "a radio button inside a tab group is a tab")
        #expect(card("AXRadioButton"), "a radio button outside a tab group asks")
        #expect(card("AXButton", label: "Run", ancestors: [MacElement(role: "AXToolbar")]), "a toolbar gives no exemption, so Run and Build ask")
        #expect(card("AXGroup", label: "Build", ancestors: [MacElement(role: "AXToolbar")]))
        #expect(!card("AXGroup", pressable: false) && !card("AXLink", pressable: false) && !card("AXStaticText", pressable: false))
        #expect(!MacSafety.requiresCard(MacElement(role: "AXButton", title: "X"), ancestors: [], strict: false))
    }

    @Test func strictClicksAreRefusedOnButtonsAndPassOnTextFields() {
        let driver = FakeDriver()
        driver.elements = [MacElement(role: "AXWindow"), MacElement(role: "AXButton", title: "Continuar", depth: 1), MacElement(role: "AXTextField", title: "Busca", depth: 1)]
        #expect(service(driver).run(arguments: ["clicar", "--titulo", "Continuar", "--estrito"]).exitCode == MacError.blocked)
        #expect(service(driver).run(arguments: ["clicar", "--titulo", "Busca", "--estrito"]).exitCode == 0)
        #expect(service(driver).run(arguments: ["clicar", "--titulo", "Continuar"]).exitCode == 0)
        #expect(driver.calls == ["press 2", "press 1"])
    }

    @Test func fullTreeKeepsQuotesAndTheWholeValue() {
        let long = "q\"" + String(repeating: "a", count: 21_000)
        let line = MacTree.line(MacElement(role: "AXTextArea", value: long), index: 0, full: true)
        #expect(line.contains("\\\"") && line.count > 21_000)
    }

    @Test func theHelperActsOnlyWhenTheNonceMatchesAFileTheServerWrote() throws {
        let driver = FakeDriver()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-callers-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nonce = String(repeating: "ab", count: 16)
        let me = getpid()
        func allowed(_ line: String?, check: @escaping (pid_t) -> Bool = { _ in true }) -> Bool {
            MacCaller.valid(nonce: line, directory: dir, processCheck: check)
        }
        #expect(!allowed(nonce), "a well-formed nonce with no file is refused")
        let file = dir.appendingPathComponent(nonce)
        FileManager.default.createFile(atPath: file.path, contents: Data("\(me)".utf8), attributes: [.posixPermissions: 0o600])
        #expect(allowed(nonce) && allowed(nonce + "\n"))
        #expect(!allowed(nil) && !allowed("curto") && !allowed(String(repeating: "z", count: 32)) && !allowed(String(repeating: "cd", count: 16)))
        #expect(!allowed("../" + nonce))
        #expect(!allowed(nonce, check: { _ in false }), "the pid must be the Wisp runtime python")
        #expect(!MacCaller.valid(nonce: nonce, directory: dir), "this test process is not the Wisp runtime")
        FileManager.default.createFile(atPath: file.path, contents: Data("999999".utf8), attributes: [.posixPermissions: 0o600])
        #expect(!allowed(nonce), "a pid that is not alive is refused")
        FileManager.default.createFile(atPath: file.path, contents: Data("not a pid".utf8), attributes: [.posixPermissions: 0o600])
        #expect(!allowed(nonce))
        FileManager.default.createFile(atPath: file.path, contents: Data("\(me)".utf8), attributes: [.posixPermissions: 0o600])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(!allowed(nonce), "a file others can read is not the server's")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let link = dir.appendingPathComponent(String(repeating: "ef", count: 16))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(!allowed(String(repeating: "ef", count: 16)), "a symlink is not accepted")
        #expect(service(driver).run(arguments: ["tecla", "cmd+t"], authorize: { false }).exitCode == MacError.refused)
        #expect(driver.calls.isEmpty)
        #expect(service(driver).run(arguments: ["permissao"], authorize: { false }).exitCode == 0)
        #expect(service(driver).run(arguments: ["selftest"], authorize: { false }).stdout == "selftest ok")
        #expect(service(driver).run(arguments: ["tecla", "cmd+t"], authorize: { allowed(nonce) }).exitCode == 0)
    }

    @Test func theNonceIsReadFromTheInheritedDescriptorWithATimeout() {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        #expect(MacCaller.readLine(from: fds[0], timeout: 50) == nil)
        _ = "abc\nrest".withCString { write(fds[1], $0, 8) }
        #expect(MacCaller.readLine(from: fds[0], timeout: 500) == "abc")
    }

    @Test func theRuntimePythonIsRecognisedByItsPath() {
        #expect(!MacCaller.isWispRuntime(getpid()))
        #expect(!MacCaller.isWispRuntime(999_999))
    }

    @Test func anyElementThatExposesPressNeedsTheCardInStrictModeWhateverItsRole() {
        func card(_ element: MacElement, _ ancestors: [MacElement] = []) -> Bool { MacSafety.requiresCard(element, ancestors: ancestors, strict: true) }
        #expect(card(MacElement(role: "AXImage", title: "x", pressable: true)))
        #expect(card(MacElement(role: "AXStaticText", pressable: true)))
        #expect(card(MacElement(role: "AXUnknown", pressable: true)))
        #expect(card(MacElement(role: "AXLink", title: "Ver", pressable: true)))
        #expect(!card(MacElement(role: "AXImage", title: "x", pressable: false)))
        #expect(!card(MacElement(role: "AXTextField", pressable: true)))
        #expect(!card(MacElement(role: "AXTab", title: "Aba", pressable: true)))
        #expect(card(MacElement(role: "AXImage"), [MacElement(role: "AXGroup"), MacElement(role: "AXButton", title: "Enviar")]), "a button ancestor counts for a point click")
        #expect(card(MacElement(role: "AXImage"), [MacElement(role: "AXGroup", pressable: true)]), "a pressable group ancestor asks too")
        #expect(card(MacElement(role: "AXImage"), [MacElement(role: "AXImage", pressable: true)]))
        #expect(!card(MacElement(role: "AXImage"), [MacElement(role: "AXToolbar")]))
        #expect(card(MacElement(role: "AXImage"), [MacElement(role: "AXToolbar", pressable: true)]), "a page posing as a toolbar is no exemption")
        #expect(!MacSafety.requiresCard(MacElement(role: "AXImage", pressable: true), ancestors: [], strict: false))
    }

    @Test func theRuntimeCheckIsAnExactPrefixOfTheRealPathUnderTheInstallLocations() {
        let home = "/Users/ana"
        for path in ["/Users/ana/.local/share/wisp/runtime/venv/bin/python3", "/Applications/Wisp.app/Contents/MacOS/Wisp",
                     "/Users/ana/Applications/Wisp.app/Contents/Resources/runtime/bin/python"] {
            #expect(MacCaller.isWispRuntimePath(path, home: home), Comment(rawValue: path))
        }
        for path in ["/tmp/wisp/runtime/evil", "/tmp/Wisp.app/Contents/MacOS/evil", "/Users/ana/Downloads/x/.local/share/wisp/runtime/python",
                     "/Users/ana/.local/share/wisp/runtime", "/Users/bob/.local/share/wisp/runtime/venv/bin/python", "/usr/bin/python3",
                     "/Applications/Wisp.app.evil/Contents/MacOS/x", "/Applications/Other.app/Contents/Wisp.app/Contents/MacOS/x"] {
            #expect(!MacCaller.isWispRuntimePath(path, home: home), Comment(rawValue: path))
        }
    }

    @Test func aSymlinkIntoTheRuntimeFromElsewhereIsNotTheRuntime() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-rt-\(UUID().uuidString.prefix(8))")
        let runtime = dir.appendingPathComponent(".local/share/wisp/runtime/bin")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = runtime.appendingPathComponent("python")
        FileManager.default.createFile(atPath: real.path, contents: Data())
        let link = dir.appendingPathComponent("elsewhere")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(MacCaller.isWispRuntimePath(real.path, home: dir.path))
        #expect(MacCaller.isWispRuntimePath(link.path, home: dir.path), "the real path is what counts, and it is inside the runtime")
        let outside = dir.appendingPathComponent("outside-python")
        FileManager.default.createFile(atPath: outside.path, contents: Data())
        let pointing = dir.appendingPathComponent(".local/share/wisp/runtime/bin/sneaky")
        try FileManager.default.createSymbolicLink(at: pointing, withDestinationURL: outside)
        #expect(!MacCaller.isWispRuntimePath(pointing.path, home: dir.path), "a link inside the runtime that points out of it is not the runtime")
    }

    @Test func hittingTheDepthCapIsTruncationJustLikeTheElementCap() {
        let driver = FakeDriver()
        driver.focused = MacFocus(app: "Mail", element: nil, window: "W")
        driver.elements = composer(body: "texto") + [MacElement(role: "AXGroup", depth: MacControlService.composeDepth)]
        #expect(service(driver).run(arguments: ["composicao"]).stderr == MacRefusal.windowTooBig)
        #expect(service(driver).run(arguments: ["enviar-janela", "--regex", "send", "--esperado", "{}"]).stderr == MacRefusal.windowTooBig)
        driver.elements = composer(body: "texto") + [MacElement(role: "AXGroup", depth: MacControlService.composeDepth - 1)]
        #expect(service(driver).run(arguments: ["composicao"]).exitCode == 0)
    }

    @Test func pointClicksOnAPressableImageInsideAButtonAreRefusedInStrictMode() {
        let driver = FakeDriver()
        let image = MacElement(role: "AXImage", x: 10, y: 10, width: 20, height: 20)
        driver.hits = [MacHit(element: image, ancestors: [MacElement(role: "AXGroup"), MacElement(role: "AXButton", title: "Continuar")], app: "Slack")]
        #expect(service(driver).run(arguments: ["clicar", "--ponto", "20,20", "--estrito"]).exitCode == MacError.blocked)
        #expect(service(driver).run(arguments: ["clicar", "--ponto", "20,20"]).exitCode == 0)
        #expect(driver.calls == ["point 20,20"])
    }

    @Test func focusReportsTheBundleIdAndWhetherTheFocusedElementIsPressable() throws {
        let driver = FakeDriver()
        driver.focused = MacFocus(app: "Calendar", element: MacElement(role: "AXButton", title: "Send", pressable: true), bundle: "com.apple.iCal")
        let out = service(driver).run(arguments: ["foco"]).stdout
        let object = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(object["bundle"] as? String == "com.apple.iCal" && object["pressavel"] as? Bool == true)
    }

    @Test func composeRefusesWhenTheTreeHitsTheCapAndTheBodyMustBeEditable() throws {
        let driver = FakeDriver()
        driver.focused = MacFocus(app: "Mail", element: nil, window: "W")
        driver.elements = [MacElement(role: "AXWindow")] + Array(repeating: MacElement(role: "AXGroup", depth: 1), count: MacControlService.composeMax - 1)
        #expect(driver.elements.count == MacControlService.composeMax)
        #expect(service(driver).run(arguments: ["composicao"]).stderr == MacRefusal.windowTooBig)
        let args = ["enviar-janela", "--regex", "send", "--esperado", "{}"]
        #expect(service(driver).run(arguments: args).stderr == MacRefusal.windowTooBig)
        driver.elements = composer(body: "texto")
        let readOnly = composer(body: "texto").map { element -> MacElement in
            var copy = element
            copy.editable = false
            return copy
        }
        #expect(MacCompose.extract(elements: readOnly, window: "").body == "")
        #expect(MacCompose.extract(elements: driver.elements, window: "").body == "texto")
    }

    @Test func theSharedEscapeVectorHoldsForTheApprovalCard() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cli/tests/fixtures/contract/escape-vector.json")
        let cases = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: String]])
        #expect(cases.count >= 8)
        for item in cases {
            #expect(PermissionRequest.escaped(try #require(item["input"])) == item["expected"], Comment(rawValue: item["name"] ?? ""))
        }
    }
}
