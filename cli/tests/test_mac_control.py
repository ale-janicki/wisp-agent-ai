import json
import os
from pathlib import Path

import pytest

from wisp import mac_control
from wisp.cli import build_parser
from wisp.mac import Falha
from wisp.mac_control import Ctx, call, cli_args, key_sends, url_intent
from wisp.paths import WispPaths
from wisp.runner import FakeRunner, RunResult
from wisp.send_gate import Refused

OK = RunResult([], 0, "", "")


@pytest.fixture
def paths(fake_home):
    return WispPaths.for_os("Darwin", fake_home, {})


@pytest.fixture
def helper(fake_home):
    path = fake_home / "wisp-mac"
    path.write_text("#!/bin/sh\n")
    path.chmod(0o755)
    return str(path)


def helper_result(helper, args, exit=0, out="", err=""):
    return {(helper, *args): RunResult([], exit, out, err)}


@pytest.fixture(autouse=True)
def no_installed_app(tmp_path, monkeypatch):
    monkeypatch.setattr(mac_control, "APP_ROOTS", (tmp_path / "system-applications",))


def ctx(paths, helper, script=None, gate=None, system="Darwin"):
    runner = FakeRunner(script or {})
    return Ctx(runner, paths, system=system, gate=gate, test_helper=Path(helper)), runner


def helper_calls(runner, helper):
    return [c[1:] for c in runner.calls if c[0] == helper]


@pytest.mark.parametrize("site,busca,url,expected", [
    ("youtube", None, None, "https://www.youtube.com"),
    ("YouTube", "lo-fi beats", None, "https://www.youtube.com/results?search_query=lo-fi+beats"),
    ("you tube", "café", None, "https://www.youtube.com/results?search_query=caf%C3%A9"),
    ("www.youtube.com", None, None, "https://www.youtube.com"),
    ("google", "tempo em Curitiba", None, "https://www.google.com/search?q=tempo+em+Curitiba"),
    ("maps", "padaria", None, "https://www.google.com/maps/search/padaria"),
    (None, "receita de bolo", None, "https://www.google.com/search?q=receita+de+bolo"),
    ("exemplo.com.br/pagina", None, None, "https://exemplo.com.br/pagina"),
    ("nubank", "fatura", None, "https://www.google.com/search?q=nubank+fatura"),
    ("whatsapp", "ana", None, "https://web.whatsapp.com"),
    (None, None, "https://exemplo.com/a?b=1", "https://exemplo.com/a?b=1"),
])
def test_url_intents(site, busca, url, expected):
    assert url_intent(site, busca, url) == expected


@pytest.mark.parametrize("url", ["file:///etc/passwd", "javascript:alert(1)", "smb://server/share", "exemplo.com", "https://", "ftp://x.y"])
def test_explicit_urls_must_be_http_or_https(url):
    with pytest.raises(Falha):
        url_intent(url=url)


def test_an_intent_needs_a_site_or_a_query():
    with pytest.raises(Falha):
        url_intent(None, None, None)


def test_opening_a_site_in_the_default_or_a_chosen_browser_builds_the_right_open_call(paths, helper, monkeypatch):
    c, runner = ctx(paths, helper, {("open",): OK})
    assert call(c, "mac_open_url", {"site": "youtube", "busca": "lo-fi"}) == "Abri https://www.youtube.com/results?search_query=lo-fi."
    monkeypatch.setattr(mac_control, "_app_instalado", lambda nome: Path("/Applications/Google Chrome.app") if nome == "Google Chrome" else None)
    call(c, "mac_open_url", {"site": "github", "navegador": "chrome"})
    assert runner.calls == [["open", "https://www.youtube.com/results?search_query=lo-fi"],
                            ["open", "-a", "/Applications/Google Chrome.app", "https://github.com"]]
    with pytest.raises(Falha, match="navegador"):
        call(c, "mac_open_url", {"site": "github", "navegador": "netscape"})


def test_opening_a_file_in_a_chosen_app_uses_open_a(paths, helper, monkeypatch, fake_home):
    pdf = fake_home / "conta.pdf"
    pdf.write_text("x")
    monkeypatch.setattr("wisp.mac._app_instalado", lambda nome: Path("/System/Applications/Preview.app"))
    c, runner = ctx(paths, helper, {("open",): OK})
    call(c, "mac_open", {"alvo": str(pdf), "com": "Preview"})
    assert runner.calls == [["open", "-a", "/System/Applications/Preview.app", str(pdf)]]


def test_the_helper_is_found_by_env_and_a_missing_one_says_where_to_get_it(paths, helper):
    c, _ = ctx(paths, helper)
    assert str(c.helper()) == helper
    missing = Ctx(FakeRunner(), paths)
    with pytest.raises(Falha, match="wisp-mac"):
        missing.helper()
    with pytest.raises(Falha, match="macOS"):
        Ctx(FakeRunner(), paths, system="Linux").helper()


def test_a_missing_accessibility_permission_reads_as_one_clear_sentence_and_a_timeout_never_hangs(paths, helper):
    c, _ = ctx(paths, helper, helper_result(helper, ["arvore", "--max", "400", "--profundidade", "8"], exit=3, err="sem permissão"))
    with pytest.raises(Falha, match="Ajustes > Controle do Mac"):
        call(c, "mac_ui_tree", {})
    slow = Ctx(FakeRunner({(helper,): RunResult([], -9, "", "", timed_out=True)}), paths, test_helper=Path(helper))
    with pytest.raises(Falha, match="demorou demais"):
        call(slow, "mac_ui_tree", {})


def test_the_tree_reaches_the_helper_with_clamped_limits_and_returns_its_text(paths, helper):
    args = ["arvore", "--max", "1500", "--profundidade", "20"]
    c, runner = ctx(paths, helper, helper_result(helper, args, out="[0] AXWindow \"Mail\""))
    assert call(c, "mac_ui_tree", {"max": 99999, "profundidade": 99}) == '[0] AXWindow "Mail"'
    assert helper_calls(runner, helper) == [args]


def focus(helper, app="Safari", secure=False):
    return helper_result(helper, ["foco"], out=json.dumps({"app": app, "papel": "AXTextField", "seguro": secure}))


def test_typing_into_a_password_field_is_refused_and_nothing_is_typed(paths, helper):
    c, runner = ctx(paths, helper, focus(helper, secure=True))
    with pytest.raises(Falha, match="senha"):
        call(c, "mac_ui_type", {"texto": "hunter2"})
    assert helper_calls(runner, helper) == [["foco"]]


def test_typing_into_a_normal_field_passes_the_text_as_one_argument(paths, helper):
    c, runner = ctx(paths, helper, {**focus(helper), (helper, "digitar"): OK})
    assert call(c, "mac_ui_type", {"texto": "oi; rm -rf ~ $(x)"}) == "Digitei 17 caracteres."
    assert helper_calls(runner, helper)[-1] == ["digitar", "oi; rm -rf ~ $(x)"]


@pytest.mark.parametrize("app", ["Mail", "Messages", "Mensagens", "WhatsApp", "Slack", "Microsoft Outlook"])
def test_a_newline_typed_into_a_messaging_app_is_refused_because_it_would_send(paths, helper, app):
    c, runner = ctx(paths, helper, {**focus(helper, app=app), (helper, "digitar"): OK})
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_ui_type", {"texto": "oi\n"})
    assert ["digitar"] not in [x[:1] for x in helper_calls(runner, helper)]


@pytest.mark.parametrize("title", ["Enviar", "Send", "send", "Enviar mensagem", "Send and Archive", "Enviar agora"])
def test_send_buttons_are_recognised(title):
    assert mac_control.send_title(title)


@pytest.mark.parametrize("title", ["Cancelar", "Anexar", "Sent", "Rascunho", "Mensagens", "Responder"])
def test_other_buttons_are_not_send_buttons(title):
    assert not mac_control.send_title(title)


@pytest.mark.parametrize("combo,sends", [
    ("return", True), ("Enter", True), ("cmd+return", True), ("command+Return", True), ("cmd+shift+d", True),
    ("shift+cmd+D", True), ("cmd+d", False), ("cmd+t", False), ("tab", False), ("cmd+shift+4", False), ("escape", False),
])
def test_keys_that_send(combo, sends):
    assert key_sends(combo) is sends


@pytest.mark.parametrize("app,blocked", [("Mail", True), ("Messages", True), ("WhatsApp", True), ("Safari", False), ("Finder", False), (None, False)])
def test_only_messaging_apps_get_the_send_block(app, blocked):
    assert mac_control.is_messenger(app) is blocked


def test_clicking_in_a_messaging_app_asks_the_helper_to_block_send_buttons_and_the_refusal_points_to_mac_send(paths, helper):
    base = ["clicar", "--titulo", "Enviar", "--indice", "0", "--app", "Mail"]
    script = {**focus(helper, app="Mail"), (helper, *base, "--bloquear", mac_control.SEND_PATTERN): RunResult([], 5, "", 'recusei: "Enviar" envia uma mensagem; use a ferramenta mac_send')}
    c, runner = ctx(paths, helper, script)
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_ui_click", {"titulo": "Enviar", "app": "Mail"})
    assert helper_calls(runner, helper)[-1] == [*base, "--bloquear", mac_control.SEND_PATTERN]


def test_clicking_in_a_normal_app_has_no_send_block_and_reports_what_was_clicked(paths, helper):
    base = ["clicar", "--titulo", "Enviar", "--indice", "0", "--app", "Safari"]
    c, runner = ctx(paths, helper, {**focus(helper), **helper_result(helper, base, out=json.dumps({"papel": "AXButton", "titulo": "Enviar"}))})
    assert call(c, "mac_ui_click", {"titulo": "Enviar", "app": "Safari"}) == "Cliquei em Enviar."
    assert helper_calls(runner, helper)[-1] == base


def test_a_click_by_point_is_judged_by_the_app_that_owns_the_element_not_the_front_app(paths, helper):
    owner = json.dumps({"papel": "AXImage", "app": "WhatsApp", "ancestrais": []})
    script = {**focus(helper, app="TextEdit"), (helper, "clicar", "--ponto", "10,20", "--resolver"): RunResult([], 0, owner, ""),
              (helper, "foco", "--app", "WhatsApp"): RunResult([], 0, json.dumps({"app": "WhatsApp", "papel": "AXTextField"}), ""),
              (helper, "clicar", "--ponto", "10,20", "--bloquear", mac_control.SEND_PATTERN): RunResult([], 0, "{}", "")}
    c, runner = ctx(paths, helper, script)
    call(c, "mac_ui_click", {"ponto": "10,20"})
    assert helper_calls(runner, helper)[-1] == ["clicar", "--ponto", "10,20", "--bloquear", mac_control.SEND_PATTERN]


def test_a_point_click_on_a_normal_app_has_no_block(paths, helper):
    owner = json.dumps({"papel": "AXButton", "app": "TextEdit"})
    script = {(helper, "clicar", "--ponto", "1,2", "--resolver"): RunResult([], 0, owner, ""), **focus(helper, app="TextEdit"),
              (helper, "clicar", "--ponto", "1,2"): RunResult([], 0, "{}", "")}
    c, runner = ctx(paths, helper, script)
    call(c, "mac_ui_click", {"ponto": "1,2"})
    assert helper_calls(runner, helper)[-1] == ["clicar", "--ponto", "1,2"]


def test_a_click_needs_something_to_click(paths, helper):
    c, _ = ctx(paths, helper)
    with pytest.raises(Falha):
        call(c, "mac_ui_click", {})


@pytest.mark.parametrize("combo", ["return", "cmd+return", "cmd+shift+d"])
def test_keys_that_send_are_refused_in_messaging_apps_without_touching_the_helper_key(paths, helper, combo):
    c, runner = ctx(paths, helper, {**focus(helper, app="Mail"), (helper, "tecla"): OK})
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_ui_key", {"tecla": combo})
    assert all(x[0] != "tecla" for x in helper_calls(runner, helper))


def test_ordinary_keys_and_shortcuts_pass_through(paths, helper):
    c, runner = ctx(paths, helper, {**focus(helper, app="Mail"), (helper, "tecla"): OK})
    call(c, "mac_ui_key", {"tecla": "cmd+t"})
    assert helper_calls(runner, helper)[-1] == ["tecla", "cmd+t"]
    c, runner = ctx(paths, helper, {**focus(helper, app="Safari"), (helper, "tecla"): OK})
    call(c, "mac_ui_key", {"tecla": "return"})
    assert helper_calls(runner, helper)[-1] == ["tecla", "return"]


def test_the_send_menu_item_is_refused_in_a_messaging_app_only(paths, helper):
    c, runner = ctx(paths, helper, {**focus(helper, app="Mail"), (helper, "menu"): OK})
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_ui_menu", {"caminho": "Mensagem > Enviar"})
    call(c, "mac_ui_menu", {"caminho": "Arquivo > Imprimir"})
    assert helper_calls(runner, helper)[-1] == ["menu", "Arquivo > Imprimir"]


def test_scroll_and_apps_build_their_helper_arguments(paths, helper):
    apps = json.dumps([{"nome": "Safari", "ativo": True, "oculto": False}, {"nome": "Mail", "ativo": False, "oculto": True}])
    c, runner = ctx(paths, helper, {(helper, "rolar"): OK, (helper, "apps"): RunResult([], 0, apps, ""), (helper, "ativar"): OK})
    call(c, "mac_ui_scroll", {"direcao": "baixo", "quantidade": 500})
    assert helper_calls(runner, helper)[-1] == ["rolar", "--direcao", "baixo", "--quantidade", "50"]
    assert call(c, "mac_apps", {}) == "- Safari (na frente)\n- Mail (escondido)"
    assert call(c, "mac_app", {"acao": "focar", "app": "Mail"}) == "Trouxe Mail para a frente."
    assert helper_calls(runner, helper)[-1] == ["ativar", "--app", "Mail"]
    with pytest.raises(Falha):
        call(c, "mac_app", {"acao": "formatar", "app": "Mail"})
    with pytest.raises(Falha):
        call(c, "mac_ui_scroll", {"direcao": "diagonal"})


BODY = "Oi Ana, chego às 18h."


def compose_tree(helper, text=BODY, to="Ana Souza"):
    args = ["arvore", "--app", "Messages", "--max", "1500", "--profundidade", "20", "--completo"]
    return helper_result(helper, args, out=f'[0] AXWindow "{to}"\n [1] AXTextArea value="{text}"')


def sending_ctx(paths, helper, gate, **extra):
    script = {**compose_tree(helper, **extra), **focus(helper, app="Messages"), (helper, "clicar"): RunResult([], 0, "{}", "")}
    return ctx(paths, helper, script, gate=gate)


def send_args(**over):
    return {"app": "Messages", "to": ["Ana"], "subject": "", "body": BODY, **over}


def test_mac_send_asks_the_host_with_an_email_shaped_request_then_clicks_send_without_the_block(paths, helper):
    asked = []
    c, runner = sending_ctx(paths, helper, asked.append)
    assert call(c, "mac_send", send_args()) == "enviado"
    assert asked == [{"to": ["Ana"], "cc": [], "subject": "", "body": BODY}]
    assert helper_calls(runner, helper)[-1] == ["clicar", "--app", "Messages", "--regex", mac_control.SEND_PATTERN, "--papel", "AXButton"]


def test_a_denied_send_clicks_nothing(paths, helper):
    def deny(request):
        raise Refused("não enviei: o usuário negou o envio.")

    c, runner = sending_ctx(paths, helper, deny)
    with pytest.raises(Falha, match="negou"):
        call(c, "mac_send", send_args())
    assert all(x[0] != "clicar" for x in helper_calls(runner, helper))


def test_without_an_approval_channel_nothing_is_sent(paths, helper):
    c, runner = sending_ctx(paths, helper, None)
    with pytest.raises(Falha, match="aprovação"):
        call(c, "mac_send", send_args())
    assert all(x[0] != "clicar" for x in helper_calls(runner, helper))


def test_the_text_shown_on_the_card_must_be_what_is_in_the_window(paths, helper):
    asked = []
    c, runner = sending_ctx(paths, helper, asked.append, text="outro texto")
    with pytest.raises(Falha, match="não é o que está escrito"):
        call(c, "mac_send", send_args())
    c, _ = sending_ctx(paths, helper, asked.append)
    with pytest.raises(Falha, match="destinatário"):
        call(c, "mac_send", send_args(to=["Beto"]))
    assert asked == [] and all(x[0] != "clicar" for x in helper_calls(runner, helper))


def test_mac_send_only_works_for_messaging_apps(paths, helper):
    c, _ = ctx(paths, helper, focus(helper, app="Safari") | {(helper, "foco"): RunResult([], 0, json.dumps({"app": "Safari", "janela": "Wikipedia", "documento": "https://pt.wikipedia.org", "papel": "AXTextField"}), "")}, gate=lambda r: None)
    with pytest.raises(Falha, match="apps de mensagem"):
        call(c, "mac_send", send_args(app="Safari"))


@pytest.mark.parametrize("script", [
    'tell application "Finder" to empty the trash',
    'do shell script "rm -rf ~/Documents"',
    'tell application "Mail" to send m',
    'tell application "Messages" to send "oi" to buddy "x"',
    'tell application "System Events" to tell process "WhatsApp" to key code 36',
])
def test_scripts_that_destroy_or_send_are_refused_before_osascript_runs(paths, helper, script):
    c, runner = ctx(paths, helper, {("osascript",): OK})
    with pytest.raises(Falha, match="Recusei"):
        call(c, "mac_script", {"script": script})
    assert runner.calls == []


def test_a_return_keystroke_script_is_refused_when_the_front_app_is_a_messenger_and_allowed_otherwise(paths, helper):
    script = 'tell application "System Events" to keystroke return'
    c, runner = ctx(paths, helper, {**focus(helper, app="Messages"), ("osascript",): OK})
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_script", {"script": script})
    assert all(x[0] != "osascript" for x in runner.calls)
    c, runner = ctx(paths, helper, {**focus(helper, app="TextEdit"), ("osascript",): OK})
    call(c, "mac_script", {"script": script})
    assert runner.calls[-1][0] == "osascript"


def test_a_harmless_script_runs_with_the_chosen_language(paths, helper):
    c, runner = ctx(paths, helper, {("osascript",): RunResult([], 0, "Macintosh HD\n", "")})
    assert call(c, "mac_script", {"script": 'tell application "Finder" to get name of startup disk'}) == "Macintosh HD"
    call(c, "mac_script", {"script": "Application('Finder').name()", "linguagem": "jxa"})
    assert runner.calls[0][:3] == ["osascript", "-e", 'tell application "Finder" to get name of startup disk']
    assert runner.calls[1][:4] == ["osascript", "-l", "JavaScript", "-e"]
    with pytest.raises(Falha, match="linguagem"):
        call(c, "mac_script", {"script": "x", "linguagem": "perl"})


def test_a_script_denied_by_macos_names_the_permission(paths, helper):
    c, _ = ctx(paths, helper, {("osascript",): RunResult([], 1, "", "Not authorized to send Apple events (-1743)")})
    with pytest.raises(Falha, match="Automação"):
        call(c, "mac_script", {"script": 'tell application "Notes" to get name of notes'})


def test_media_builds_a_script_only_for_music_and_spotify(paths, helper):
    c, runner = ctx(paths, helper, {("osascript",): RunResult([], 0, "ok", "")})
    assert call(c, "mac_media", {"acao": "alternar", "app": "Spotify"}) == "Spotify: alternar."
    assert runner.calls[0] == ["osascript", "-e", 'if application "Spotify" is running then', "-e", 'tell application "Spotify" to playpause',
                               "-e", 'return "ok"', "-e", "end if", "-e", 'return "fechado"']
    for acao, app in (("explodir", "Music"), ("tocar", "Safari")):
        with pytest.raises(Falha):
            call(c, "mac_media", {"acao": acao, "app": app})
    closed, _ = ctx(paths, helper, {("osascript",): RunResult([], 0, "fechado", "")})
    assert "não está aberto" in call(closed, "mac_media", {"acao": "proxima"})


def test_brightness_dark_mode_and_settings_panes(paths, helper):
    c, runner = ctx(paths, helper, {("osascript",): OK, ("brightness",): RunResult([], 127, "", "no"), ("open",): OK})
    call(c, "mac_brightness", {"valor": "mais"})
    assert runner.calls[0].count("-e") == mac_control.BRIGHTNESS_STEPS and "key code 144" in runner.calls[0][1:][1]
    with pytest.raises(Falha, match="brightness"):
        call(c, "mac_brightness", {"valor": "50"})
    with pytest.raises(Falha):
        call(c, "mac_brightness", {"valor": "150"})
    call(c, "mac_dark_mode", {"modo": "escuro"})
    assert runner.calls[-1][-1].endswith("set dark mode to true")
    with pytest.raises(Falha):
        call(c, "mac_dark_mode", {"modo": "roxo"})
    call(c, "mac_settings_pane", {"painel": "Acessibilidade"})
    assert runner.calls[-1] == ["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]
    with pytest.raises(Falha, match="Painéis"):
        call(c, "mac_settings_pane", {"painel": "https://evil.example"})


def test_wifi_reads_power_and_network(paths, helper):
    ports = "Hardware Port: Ethernet\nDevice: en5\n\nHardware Port: Wi-Fi\nDevice: en0\nEthernet Address: x\n"
    script = {("networksetup", "-listallhardwareports"): RunResult([], 0, ports, ""),
              ("networksetup", "-getairportpower", "en0"): RunResult([], 0, "Wi-Fi Power (en0): On\n", ""),
              ("networksetup", "-getairportnetwork", "en0"): RunResult([], 0, "Current Wi-Fi Network: Casa\n", "")}
    c, _ = ctx(paths, helper, script)
    assert call(c, "mac_wifi", {}) == "O Wi-Fi está ligado, na rede Casa."
    script[("networksetup", "-getairportpower", "en0")] = RunResult([], 0, "Wi-Fi Power (en0): Off\n", "")
    assert call(ctx(paths, helper, script)[0], "mac_wifi", {}) == "O Wi-Fi está desligado."


def allow_shortcuts(paths, *names):
    paths.config.mkdir(parents=True, exist_ok=True)
    (paths.config / mac_control.SHORTCUT_ALLOWLIST).write_text(json.dumps(list(names)))


def test_a_shortcut_runs_by_name_and_its_input_file_is_removed(paths, helper):
    allow_shortcuts(paths, "Modo Foco")
    c, runner = ctx(paths, helper, {("shortcuts",): RunResult([], 0, "feito\n", "")})
    assert call(c, "mac_shortcut", {"nome": "Modo Foco", "entrada": "25"}) == "feito"
    assert runner.calls[0][:3] == ["shortcuts", "run", "Modo Foco"] and runner.calls[0][3] == "--input-path"
    assert not Path(runner.calls[0][4]).exists()
    with pytest.raises(Falha):
        call(c, "mac_shortcut", {"nome": " "})


@pytest.mark.parametrize("nome", ["Enviar relatório", "Send to Ana", "Mandar mensagem", "Email para o chefe", "Qualquer coisa"])
def test_a_shortcut_that_may_send_or_is_not_on_the_read_only_list_needs_the_card(paths, helper, nome):
    allow_shortcuts(paths, "Modo Foco", "Enviar relatório")
    c, runner = ctx(paths, helper, {("shortcuts",): OK})
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_shortcut", {"nome": nome})
    assert runner.calls == []


def test_a_shortcut_goes_through_the_send_card_and_runs_only_after_the_approval(paths, helper):
    asked = []
    c, runner = ctx(paths, helper, {("shortcuts",): RunResult([], 0, "", "")}, gate=asked.append)
    assert call(c, "mac_send", {"app": "Atalhos", "to": ["Enviar relatório"], "subject": "Rodar atalho", "body": "semana 47"}) == "enviado"
    assert asked == [{"to": ["Enviar relatório"], "cc": [], "subject": "Rodar atalho", "body": "semana 47"}]
    assert runner.calls[0][:3] == ["shortcuts", "run", "Enviar relatório"]

    def deny(request):
        raise Refused("não enviei: o usuário negou o envio.")

    c, runner = ctx(paths, helper, {("shortcuts",): OK}, gate=deny)
    with pytest.raises(Falha, match="negou"):
        call(c, "mac_send", {"app": "Shortcuts", "to": ["X"], "subject": "s", "body": "X"})
    assert runner.calls == []


def test_a_screenshot_of_an_app_captures_its_window_id(paths, helper):
    windows = json.dumps([{"id": 4242, "app": "Safari", "titulo": "", "largura": 800, "altura": 600}])
    seen = {}

    def runner_run(argv, **kw):
        seen.setdefault("calls", []).append(list(argv))
        if argv[0] == "screencapture":
            Path(argv[-1]).write_bytes(b"png")
            return OK
        return RunResult(list(argv), 0, windows, "")

    c = Ctx(FakeRunner(), paths, test_helper=Path(helper))
    c.runner.run = runner_run
    path = call(c, "mac_screenshot", {"app": "Safari"})
    assert Path(path).is_file()
    assert seen["calls"][-1][:5] == ["screencapture", "-x", "-o", "-l", "4242"]


def test_every_action_is_logged_before_and_after_and_typed_text_is_never_stored(paths, helper):
    c, _ = ctx(paths, helper, {**focus(helper), (helper, "digitar"): OK})
    call(c, "mac_ui_type", {"texto": "minha-senha-secreta"})
    lines = [json.loads(x) for x in (paths.state / mac_control.LOG_NAME).read_text().splitlines()]
    assert [(x["ferramenta"], x["fase"]) for x in lines] == [("mac_ui_type", "pedido"), ("mac_ui_type", "feito")]
    assert "secreta" not in json.dumps(lines) and lines[0]["args"]["texto"] == "<19 caracteres>"
    with pytest.raises(Falha):
        call(c, "mac_ui_key", {"tecla": ""})
    refused = ctx(paths, helper, focus(helper, secure=True))[0]
    with pytest.raises(Falha):
        call(refused, "mac_ui_type", {"texto": "x"})
    last = json.loads((paths.state / mac_control.LOG_NAME).read_text().splitlines()[-1])
    assert last["fase"] == "recusado"


def test_an_action_that_cannot_be_logged_is_not_executed(paths, helper, fake_home):
    blocker = fake_home / "state-is-a-file"
    blocker.write_text("x")
    blocked = WispPaths(paths.home, paths.config, paths.runtime, blocker, paths.bin, None)
    c, runner = ctx(blocked, helper, {("open",): OK})
    with pytest.raises(Falha, match="registrar"):
        call(c, "mac_open_url", {"site": "youtube"})
    assert runner.calls == []


def test_unknown_tools_and_missing_arguments_fail_clearly(paths, helper):
    c, _ = ctx(paths, helper)
    with pytest.raises(Falha, match="não existe"):
        call(c, "mac_format_disk", {})
    with pytest.raises(Falha, match="faltou"):
        call(c, "mac_volume", {})


def test_read_only_tools_are_exactly_the_ones_that_change_nothing():
    assert mac_control.READ_ONLY == {"mac_apps", "mac_windows", "mac_ui_tree", "mac_battery", "mac_wifi", "mac_dnd_status",
                                     "mac_screenshot", "mac_shortcuts_list"}
    assert mac_control.ALWAYS_ASK == {"mac_send"}
    for tool in mac_control.TOOLS.values():
        assert set(tool.required) <= set(tool.properties) and tool.name.startswith("mac_")


def test_the_cli_parses_every_new_command_into_its_tool_and_arguments():
    parse = build_parser().parse_args
    a = parse(["mac", "abrir-url", "--site", "youtube", "--busca", "lo-fi", "--navegador", "safari"])
    assert a.tool == "mac_open_url" and cli_args(a) == {"site": "youtube", "busca": "lo-fi", "navegador": "safari"}
    a = parse(["mac", "clicar", "--titulo", "OK", "--indice", "2"])
    assert a.tool == "mac_ui_click" and cli_args(a) == {"titulo": "OK", "indice": 2}
    assert cli_args(parse(["mac", "tecla", "cmd+t"])) == {"tecla": "cmd+t"}
    assert cli_args(parse(["mac", "rolar", "baixo", "--quantidade", "7"])) == {"direcao": "baixo", "quantidade": 7}
    assert cli_args(parse(["mac", "app", "sair", "Mail"])) == {"acao": "sair", "app": "Mail"}
    assert cli_args(parse(["mac", "script", "return 1", "--linguagem", "jxa"])) == {"script": "return 1", "linguagem": "jxa"}
    assert parse(["mac", "midia", "proxima", "--app", "Spotify"]).tool == "mac_media"
    assert getattr(parse(["mac", "volume", "30"]), "tool", None) is None
    with pytest.raises(SystemExit):
        parse(["mac", "enviar", "--app", "Mail"])


def info(app, documento="", janela="", papel="AXTextField", seguro=False):
    return RunResult([], 0, json.dumps({"app": app, "documento": documento, "janela": janela, "papel": papel, "seguro": seguro}), "")


@pytest.mark.parametrize("script", [
    'tell application "System Events" to keystroke "d" using {command down, shift down}',
    'tell application "System Events" to keystroke "D" using { shift down , command down }',
    "Application('System Events').keystroke('d', {using: ['command down', 'shift down']})",
    "Application('System Events').keyCode(36)",
    'tell application "System Events" to key code (36)',
    'tell application "System Events" to  KEY   CODE   76',
    'tell application "System Events" to keystroke (character id 13)',
    'tell application "System Events" to keystroke (ASCII character 13)',
    'tell application "System Events" to keystroke return using command down',
    'tell application "System Events" to tell process "Foo" to click button "Send" of window 1',
    "tell application \"System Events\" to tell process \"Foo\" to click button 'Enviar' of window 1",
])
def test_send_keystrokes_and_send_clicks_are_refused_in_any_spelling_when_a_messenger_or_browser_is_in_front(paths, helper, script):
    for app in ("Messages", "Google Chrome"):
        c, runner = ctx(paths, helper, {(helper, "foco"): info(app), ("osascript",): OK})
        with pytest.raises(Falha, match="mac_send"):
            call(c, "mac_script", {"script": script})
        assert all(x[0] != "osascript" for x in runner.calls)


def test_a_send_keystroke_is_allowed_when_a_plain_app_is_in_front_and_a_system_events_script_is_refused_in_a_messenger(paths, helper):
    script = 'tell application "System Events" to keystroke "d" using {command down, shift down}'
    c, runner = ctx(paths, helper, {(helper, "foco"): info("TextEdit"), ("osascript",): OK})
    call(c, "mac_script", {"script": script})
    assert runner.calls[-1][0] == "osascript"
    typed = 'tell application "System Events" to keystroke "hello"'
    c, runner = ctx(paths, helper, {(helper, "foco"): info("Slack"), ("osascript",): OK})
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_script", {"script": typed})
    c, runner = ctx(paths, helper, {(helper, "foco"): info("TextEdit"), ("osascript",): OK})
    call(c, "mac_script", {"script": typed})


def test_a_send_button_click_script_is_refused_even_with_a_plain_app_in_front(paths, helper):
    c, runner = ctx(paths, helper, {(helper, "foco"): info("TextEdit"), ("osascript",): OK})
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_script", {"script": 'tell application "System Events" to tell process "Foo" to click button "Send" of window 1'})
    assert runner.calls == []


@pytest.mark.parametrize("app", ["Thunderbird", "Spark", "zoom.us", "Skype", "Messenger", "Microsoft Teams"])
def test_the_extra_messaging_apps_get_the_send_block(app):
    assert mac_control.is_messenger(app)


@pytest.mark.parametrize("documento,janela,expected", [
    ("https://mail.google.com/mail/u/0/#inbox", "Entrada", True),
    ("https://outlook.live.com/mail/0/", "", True),
    ("https://outlook.office.com/mail", "", True),
    ("https://web.whatsapp.com/", "", True),
    ("https://www.messenger.com/t/1", "", True),
    ("https://web.telegram.org/a/", "", True),
    ("https://discord.com/channels/1", "", True),
    ("https://app.slack.com/client/T1", "", True),
    ("https://teams.microsoft.com/v2/", "", True),
    ("", "Inbox (3) - Gmail", True),
    ("https://pt.wikipedia.org/wiki/Mail", "Mail - Wikipédia", False),
    ("https://exemplo.com", "Exemplo", False),
])
def test_a_browser_showing_webmail_or_chat_counts_as_a_messenger(documento, janela, expected):
    assert mac_control.sensitive({"app": "Google Chrome", "documento": documento, "janela": janela}) is expected


def test_the_browser_is_judged_by_the_page_not_by_its_name(paths, helper):
    gmail = info("Google Chrome", documento="https://mail.google.com/mail/u/0/")
    script = {(helper, "foco"): gmail, (helper, "clicar", "--titulo", "Enviar", "--indice", "0", "--bloquear", mac_control.SEND_PATTERN): RunResult([], 5, "", "recusei: mac_send")}
    c, runner = ctx(paths, helper, script)
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_ui_click", {"titulo": "Enviar"})
    plain = {(helper, "foco"): info("Google Chrome", documento="https://exemplo.com"), (helper, "clicar"): RunResult([], 0, "{}", "")}
    c, runner = ctx(paths, helper, plain)
    call(c, "mac_ui_click", {"titulo": "Enviar"})
    assert "--bloquear" not in helper_calls(runner, helper)[-1]
    c, runner = ctx(paths, helper, {(helper, "foco"): gmail, (helper, "tecla"): OK})
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_ui_key", {"tecla": "cmd+return"})


def test_mac_send_works_in_a_webmail_tab_after_the_card(paths, helper):
    gmail = info("Google Chrome", documento="https://mail.google.com/mail/u/0/")
    tree = helper_result(helper, ["arvore", "--app", "Google Chrome", "--max", "1500", "--profundidade", "20", "--completo"],
                         out='[0] AXWebArea "Gmail" [1] AXTextArea value="Oi Ana, chego às 18h." [2] AXTextField value="ana@x.com"')
    asked = []
    c, runner = ctx(paths, helper, {(helper, "foco"): gmail, **tree, (helper, "clicar"): RunResult([], 0, "{}", "")}, gate=asked.append)
    assert call(c, "mac_send", {"app": "Google Chrome", "to": ["ana@x.com"], "subject": "s", "body": BODY}) == "enviado"
    assert len(asked) == 1


def test_a_helper_environment_variable_is_never_honoured(paths, helper, monkeypatch):
    monkeypatch.setenv("WISP_MAC_BIN", helper)
    with pytest.raises(Falha, match="wisp-mac"):
        Ctx(FakeRunner(), paths).helper()


def install_helper(fake_home):
    app = fake_home / "Applications/Wisp.app"
    path = app / "Contents/Helpers/wisp-mac"
    path.parent.mkdir(parents=True)
    path.write_text("#!/bin/sh\n")
    path.chmod(0o755)
    return app, path


def codesign_script(app, path, team="ABCDE12345", verify_exit=0):
    shown = f"Identifier=ai.wisp.app\nTeamIdentifier={team}\n" if team else "TeamIdentifier=not set\n"
    script = {("codesign", "-dvv", str(app)): RunResult([], 0, "", shown)}
    if not team:
        script[("codesign", "-d", "-r-", str(app))] = RunResult([], 0, "", 'designated => identifier "ai.wisp.app" and certificate leaf = H"' + "ab" * 20 + '"')
    requirement = f'anchor apple generic and certificate leaf[subject.OU] = "{team}"' if team else 'certificate leaf = H"' + "ab" * 20 + '"'
    script[("codesign", "--verify", "--strict", "-R=" + requirement, str(path))] = RunResult([], verify_exit, "", "")
    script[(str(path),)] = RunResult([], 0, "{}", "")
    return script, requirement


def test_the_helper_is_run_only_after_its_signature_matches_the_apps_team(paths, fake_home):
    app, path = install_helper(fake_home)
    script, requirement = codesign_script(app, path)
    runner = FakeRunner(script)
    c = Ctx(runner, paths)
    assert c.helper_run("apps") == "{}"
    assert ["codesign", "--verify", "--strict", "-R=" + requirement, str(path)] in runner.calls
    runner.calls.clear()
    c.helper_run("apps")
    assert not any(x[0] == "codesign" for x in runner.calls), "verified once per binary"


def test_a_helper_with_another_signature_is_refused_and_never_executed(paths, fake_home):
    app, path = install_helper(fake_home)
    script, _ = codesign_script(app, path, verify_exit=3)
    runner = FakeRunner(script)
    with pytest.raises(Falha, match="assinatura"):
        Ctx(runner, paths).helper_run("apps")
    assert not any(x[0] == str(path) for x in runner.calls)


def test_a_self_signed_app_is_matched_by_its_certificate_and_an_unsigned_one_is_refused(paths, fake_home):
    app, path = install_helper(fake_home)
    script, _ = codesign_script(app, path, team=None)
    assert Ctx(FakeRunner(script), paths).helper_run("apps") == "{}"
    runner = FakeRunner({("codesign", "-dvv", str(app)): RunResult([], 0, "", "TeamIdentifier=not set\n"), ("codesign", "-d", "-r-", str(app)): RunResult([], 0, "", "designated => cdhash H\"aa\"")})
    with pytest.raises(Falha, match="assinatura"):
        Ctx(runner, paths).helper_run("apps")


@pytest.mark.parametrize("combo", ["cmd+v", "return", "tab", "cmd+a"])
def test_keys_into_a_password_field_are_refused(paths, helper, combo):
    c, runner = ctx(paths, helper, {(helper, "foco"): info("Safari", seguro=True), (helper, "tecla"): OK})
    with pytest.raises(Falha, match="senha"):
        call(c, "mac_ui_key", {"tecla": combo})
    assert all(x[0] != "tecla" for x in helper_calls(runner, helper))


def test_keys_and_typing_fail_closed_when_the_focused_element_cannot_be_read(paths, helper):
    blind = RunResult([], 0, json.dumps({"app": "Safari"}), "")
    c, runner = ctx(paths, helper, {(helper, "foco"): blind, (helper, "tecla"): OK, (helper, "digitar"): OK})
    for name, args in (("mac_ui_key", {"tecla": "cmd+v"}), ("mac_ui_type", {"texto": "x"})):
        with pytest.raises(Falha, match="não consegui ver"):
            call(c, name, args)
    broken = RunResult([], 1, "", "falhou")
    c, runner = ctx(paths, helper, {(helper, "foco"): broken, (helper, "digitar"): OK})
    with pytest.raises(Falha):
        call(c, "mac_ui_type", {"texto": "x"})
    assert all(x[0] != "digitar" for x in helper_calls(runner, helper))


def test_the_log_is_private_and_mac_send_and_shortcut_inputs_are_redacted(paths, helper):
    asked = []
    tree = compose_tree(helper)
    c, _ = ctx(paths, helper, {**tree, **focus(helper, app="Messages"), (helper, "clicar"): RunResult([], 0, "{}", "")}, gate=asked.append)
    call(c, "mac_send", send_args(subject="assunto secreto"))
    allow_shortcuts(paths, "Modo Foco")
    c2, _ = ctx(paths, helper, {("shortcuts",): RunResult([], 0, "saída secreta", "")})
    call(c2, "mac_shortcut", {"nome": "Modo Foco", "entrada": "entrada secreta"})
    log = paths.state / mac_control.LOG_NAME
    text = log.read_text()
    assert "secret" not in text and "chego" not in text and "Ana" not in text
    assert oct(log.stat().st_mode & 0o777) == "0o600" and oct(paths.state.stat().st_mode & 0o777) == "0o700"
    assert '"body": "<21 caracteres>"' in text and '"entrada": "<15 caracteres>"' in text


def test_the_codex_registration_never_forwards_a_helper_path():
    from wisp.setup.codex import mcp_overrides, render_config_block

    assert not any("WISP_MAC_BIN" in line for line in mcp_overrides("/w") + mcp_overrides("/w", allow_changes=False))
    assert "WISP_MAC_BIN" not in render_config_block("/w")


def test_the_watchdog_message_warns_that_typed_text_may_remain():
    source = (Path(__file__).parents[2] / "app/MacControl/main.swift").read_text()
    assert "texto digitado pela metade pode ter ficado" in source


def test_the_new_modules_carry_no_comments_or_docstrings():
    import ast
    import io
    import tokenize

    root = Path(mac_control.__file__).parent
    for name in ("mac_control.py", "mac_server.py"):
        text = (root / name).read_text()
        assert not [t for t in tokenize.generate_tokens(io.StringIO(text).readline) if t.type == tokenize.COMMENT], name
        tree = ast.parse(text)
        assert ast.get_docstring(tree) is None, name
        assert not [n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and ast.get_docstring(n)], name
