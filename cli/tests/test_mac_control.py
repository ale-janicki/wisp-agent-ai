import json
import os
from pathlib import Path

import pytest

from wisp import mac_control
from wisp.cli import build_parser
from wisp.mac import Falha
from wisp.mac_control import Ctx, call, cli_args, key_is_safe, url_intent
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


BUNDLES = {
    "Finder": "com.apple.finder", "Preview": "com.apple.Preview", "System Settings": "com.apple.systempreferences", "Music": "com.apple.Music",
    "Spotify": "com.spotify.client", "Calculator": "com.apple.calculator", "Calendar": "com.apple.iCal", "Notes": "com.apple.Notes",
    "TextEdit": "com.apple.TextEdit", "Pages": "com.apple.iWork.Pages", "Numbers": "com.apple.iWork.Numbers", "Keynote": "com.apple.iWork.Keynote",
    "Safari": "com.apple.Safari", "Google Chrome": "com.google.Chrome", "Firefox": "org.mozilla.firefox", "Arc": "company.thebrowser.Browser",
    "Mail": "com.apple.mail", "Messages": "com.apple.MobileSMS", "WhatsApp": "net.whatsapp.WhatsApp", "Slack": "com.tinyspeck.slackmacgap",
    "Discord": "com.hnc.Discord", "Terminal": "com.apple.Terminal", "iTerm2": "com.googlecode.iterm2", "iTerm": "com.googlecode.iterm2",
    "Xcode": "com.apple.dt.Xcode", "Warp": "dev.warp.Warp-Stable", "Ghostty": "com.mitchellh.ghostty", "kitty": "net.kovidgoyal.kitty",
    "Alacritty": "org.alacritty", "Visual Studio Code": "com.microsoft.VSCode", "Code": "com.microsoft.VSCode", "Cursor": "com.todesktop.230313mzl4w4u92",
    "Script Editor": "com.apple.ScriptEditor2", "WezTerm": "com.github.wez.wezterm", "PyCharm": "com.jetbrains.pycharm", "Automator": "com.apple.Automator",
    "Notion": "notion.id", "Linear": "com.linear", "Raycast": "com.raycast.macos",
}


def bundle_of(app):
    return BUNDLES.get(app, "com.example." + "".join(c for c in app.lower() if c.isalnum()))


def focus(helper, app="Safari", secure=False):
    return helper_result(helper, ["foco"], out=json.dumps({"app": app, "bundle": bundle_of(app), "papel": "AXTextField", "seguro": secure}))


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






@pytest.mark.parametrize("app,blocked", [("Mail", True), ("Messages", True), ("WhatsApp", True), ("Safari", False), ("Finder", False), (None, False)])
def test_only_messaging_apps_get_the_send_block(app, blocked):
    assert mac_control.is_messenger(app) is blocked


def test_clicking_in_a_messaging_app_asks_the_helper_to_block_send_buttons_and_the_refusal_points_to_mac_send(paths, helper):
    base = ["clicar", "--titulo", "Enviar", "--indice", "0", "--app", "Mail"]
    script = {**focus(helper, app="Mail"), (helper, *base, "--bloquear", mac_control.SEND_PATTERN, "--estrito"): RunResult([], 5, "", 'recusei: "Enviar" envia uma mensagem; use a ferramenta mac_send')}
    c, runner = ctx(paths, helper, script)
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_ui_click", {"titulo": "Enviar", "app": "Mail"})
    assert helper_calls(runner, helper)[-1] == [*base, "--bloquear", mac_control.SEND_PATTERN, "--estrito"]




def test_a_click_by_point_is_judged_by_the_app_that_owns_the_element_not_the_front_app(paths, helper):
    owner = json.dumps({"papel": "AXImage", "app": "WhatsApp", "ancestrais": []})
    script = {**focus(helper, app="TextEdit"), (helper, "clicar", "--ponto", "10,20", "--resolver"): RunResult([], 0, owner, ""),
              (helper, "foco", "--app", "WhatsApp"): RunResult([], 0, json.dumps({"app": "WhatsApp", "papel": "AXTextField"}), ""),
              (helper, "clicar", "--ponto", "10,20", "--bloquear", mac_control.SEND_PATTERN, "--estrito"): RunResult([], 0, "{}", "")}
    c, runner = ctx(paths, helper, script)
    call(c, "mac_ui_click", {"ponto": "10,20"})
    assert helper_calls(runner, helper)[-1] == ["clicar", "--ponto", "10,20", "--bloquear", mac_control.SEND_PATTERN, "--estrito"]




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


def info(app, documento="", janela="", papel="AXTextField", seguro=False, bundle=None, pressavel=False, titulo=""):
    data = {"app": app, "bundle": bundle_of(app) if bundle is None else bundle, "documento": documento, "janela": janela, "papel": papel,
            "seguro": seguro, "pressavel": pressavel, "titulo": titulo}
    return RunResult([], 0, json.dumps(data), "")








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


@pytest.mark.parametrize("title", ["Cancelar", "Anexar", "Sent", "Rascunho", "Mensagens"])
def test_other_buttons_are_not_send_buttons(title):
    assert not mac_control.send_title(title)


@pytest.mark.parametrize("title", ["Enviar", "Send", "Senden", "Envoyer", "Submit", "Post", "Publicar", "Responder", "Reply"])
def test_the_send_like_labels_in_other_languages_are_recognised(title):
    assert mac_control.send_title(title)


def settings_plist(**values):
    import plistlib

    return RunResult([], 0, plistlib.dumps(values).decode(), "")


def with_settings(script, **values):
    return {**script, ("defaults", "export", "ai.wisp.app", "-"): settings_plist(**values)}






@pytest.mark.parametrize("app", ["Slack", "Mail", "Safari", "Google Chrome", "Firefox", "Arc", "Pages Pro", "Notion", "Linear", "Cursor", "Discord"])
def test_every_other_app_needs_the_card_for_return_newlines_and_send_labels(paths, helper, app):
    script = {(helper, "foco"): info(app, documento="https://exemplo.com"), (helper, "tecla"): OK, (helper, "digitar"): OK,
              (helper, "clicar", "--titulo", "Submit", "--indice", "0", "--app", app, "--bloquear", mac_control.SEND_PATTERN, "--estrito"): RunResult([], 5, "", "recusei: mac_send")}
    c, runner = ctx(paths, helper, script)
    for name, args in (("mac_ui_key", {"tecla": "return"}), ("mac_ui_key", {"tecla": "cmd+enter"}), ("mac_ui_type", {"texto": "a\nb"}),
                       ("mac_ui_click", {"titulo": "Submit", "app": app}), ("mac_ui_menu", {"caminho": "Mensagem > Enviar"})):
        with pytest.raises(Falha, match="mac_send"):
            call(c, name, args)
    assert all(x[0] not in ("tecla", "digitar", "menu") for x in helper_calls(runner, helper))










BODY = "Oi \"Ana\", chego às 18h.\nBeijo"


def window(helper, app="Messages", corpo=BODY, destinatarios=("Ana Souza",), assunto="", janela="Ana Souza", documento="", cc=(), bcc=()):
    data = {"app": app, "corpo": corpo, "destinatarios": list(destinatarios), "cc": list(cc), "bcc": list(bcc), "assunto": assunto,
            "janela": janela, "documento": documento}
    return {(helper, "composicao"): RunResult([], 0, json.dumps(data, ensure_ascii=False), ""),
            (helper, "foco"): info(app, documento=documento), (helper, "enviar-janela"): RunResult([], 0, "{}", "")}


def send_args(**over):
    return {"app": "Messages", "to": ["Ana Souza"], "subject": "", "body": BODY, **over}




def test_a_body_with_quotes_and_a_long_text_still_matches_exactly(paths, helper):
    long = 'ele disse "oi" e ' + "x" * 25_000
    asked = []
    c, _ = ctx(paths, helper, window(helper, corpo=long), gate=asked.append)
    assert call(c, "mac_send", send_args(body=long)) == "enviado" and asked[0]["body"] == long


def test_a_body_that_is_only_contained_in_the_window_is_not_enough(paths, helper):
    asked = []
    c, runner = ctx(paths, helper, window(helper, corpo=BODY + " e mais um monte de coisa"), gate=asked.append)
    with pytest.raises(Falha, match="não é igual"):
        call(c, "mac_send", send_args())
    c, _ = ctx(paths, helper, window(helper, corpo="x" + BODY), gate=asked.append)
    with pytest.raises(Falha, match="não é igual"):
        call(c, "mac_send", send_args())
    assert asked == []




@pytest.mark.parametrize("to", [["Beto"], ["Ana Souza", "Beto"], [], ["ana souza"], ["Ana"]])
def test_recipients_must_equal_the_to_field_of_the_window(paths, helper, to):
    asked = []
    c, runner = ctx(paths, helper, window(helper), gate=asked.append)
    with pytest.raises(Falha):
        call(c, "mac_send", send_args(to=to))
    assert asked == [] and all(x[0] != "enviar-janela" for x in helper_calls(runner, helper))


def test_an_empty_recipient_field_in_an_email_app_refuses_instead_of_guessing(paths, helper):
    c, _ = ctx(paths, helper, window(helper, app="Mail", destinatarios=(), janela="Nova mensagem"), gate=lambda r: None)
    with pytest.raises(Falha, match="para quem"):
        call(c, "mac_send", send_args(app="Mail", to=["Nova mensagem"]))


def test_a_chat_app_without_a_to_field_uses_the_conversation_title(paths, helper):
    asked = []
    c, _ = ctx(paths, helper, window(helper, destinatarios=(), janela="Ana Souza"), gate=asked.append)
    assert call(c, "mac_send", send_args()) == "enviado" and asked[0]["to"] == ["Ana Souza"]


def test_the_subject_must_equal_the_subject_field(paths, helper):
    c, _ = ctx(paths, helper, window(helper, app="Mail", assunto="Reunião", destinatarios=("a@x.com",)), gate=lambda r: None)
    with pytest.raises(Falha, match="assunto"):
        call(c, "mac_send", send_args(app="Mail", to=["a@x.com"], subject="Outro"))
    assert call(c, "mac_send", send_args(app="Mail", to=["a@x.com"], subject="Reunião")) == "enviado"




def test_a_denied_send_clicks_nothing_and_no_channel_means_no_send(paths, helper):
    def deny(request):
        raise Refused("não enviei: o usuário negou o envio.")

    c, runner = ctx(paths, helper, window(helper), gate=deny)
    with pytest.raises(Falha, match="negou"):
        call(c, "mac_send", send_args())
    c, runner = ctx(paths, helper, window(helper), gate=None)
    with pytest.raises(Falha, match="aprovação"):
        call(c, "mac_send", send_args())
    assert all(x[0] != "enviar-janela" for x in helper_calls(runner, helper))


def test_mac_send_in_a_webmail_tab_reads_the_composer_and_the_card_shows_the_page_values(paths, helper):
    asked = []
    script = window(helper, app="Google Chrome", destinatarios=("ana@x.com",), assunto="Oi", documento="https://mail.google.com/mail/u/0/", janela="Nova")
    c, _ = ctx(paths, helper, script, gate=asked.append)
    assert call(c, "mac_send", send_args(app="Google Chrome", to=["ana@x.com"], subject="Oi")) == "enviado"
    assert asked[0]["app"] == "Google Chrome"
    plain = window(helper, app="Google Chrome", documento="https://exemplo.com")
    c, _ = ctx(paths, helper, plain, gate=asked.append)
    with pytest.raises(Falha, match="webmail"):
        call(c, "mac_send", send_args(app="Google Chrome"))


def test_unnormalised_input_is_refused_so_the_ticket_bytes_equal_what_was_shown(paths, helper):
    c, _ = ctx(paths, helper, window(helper), gate=lambda r: None)
    for over in ({"body": BODY + "  "}, {"body": BODY.replace("\n", "\r\n")}, {"to": [" Ana Souza"]}):
        with pytest.raises(Falha, match="espaços sobrando"):
            call(c, "mac_send", send_args(**over))


def test_a_key_press_goes_through_the_card_then_the_helper_after_the_allow(paths, helper):
    asked = []
    script = {(helper, "foco"): info("Slack"), (helper, "tecla"): OK}
    c, runner = ctx(paths, helper, script, gate=asked.append)
    args = {"app": "Slack", "to": ["return"], "subject": "tecla", "body": "return", "acao": "tecla"}
    assert call(c, "mac_send", args) == "feito"
    assert asked == [{"app": "Slack", "to": ["return"], "cc": [], "subject": "tecla", "body": "return"}]
    assert helper_calls(runner, helper)[-1] == ["tecla", "return", "--app", "Slack"]
    with pytest.raises(Falha, match="assunto"):
        call(c, "mac_send", {**args, "subject": "outra"})


def test_typed_text_with_a_newline_and_a_labelled_click_go_through_the_card(paths, helper):
    asked = []
    script = {(helper, "foco"): info("Notion"), (helper, "digitar"): OK, (helper, "clicar"): RunResult([], 0, "{}", "")}
    c, runner = ctx(paths, helper, script, gate=asked.append)
    call(c, "mac_send", {"app": "Notion", "to": ["Notion"], "subject": "texto", "body": "linha 1\nlinha 2", "acao": "texto"})
    call(c, "mac_send", {"app": "Notion", "to": ["Publicar"], "subject": "clique", "body": "Publicar", "acao": "clique"})
    assert [a["subject"] for a in asked] == ["texto", "clique"]
    acted = [x for x in helper_calls(runner, helper) if x[0] in ("digitar", "clicar")]
    assert acted == [["digitar", "linha 1\nlinha 2", "--app", "Notion"], ["clicar", "--titulo", "Publicar", "--indice", "0", "--app", "Notion"]]


def test_a_card_approved_action_still_refuses_password_fields_and_a_changed_app(paths, helper):
    c, runner = ctx(paths, helper, {(helper, "foco"): info("Slack", seguro=True), (helper, "digitar"): OK}, gate=lambda r: None)
    with pytest.raises(Falha, match="senha"):
        call(c, "mac_send", {"app": "Slack", "to": ["Slack"], "subject": "texto", "body": "x\ny", "acao": "texto"})
    c, runner = ctx(paths, helper, {(helper, "foco"): info("Safari"), (helper, "digitar"): OK}, gate=lambda r: None)
    with pytest.raises(Falha, match="janela mudou"):
        call(c, "mac_send", {"app": "Slack", "to": ["Slack"], "subject": "texto", "body": "x\n", "acao": "texto"})
    assert all(x[0] != "digitar" for x in helper_calls(runner, helper))


SCRIPT = 'tell application "Finder" to get name of startup disk'


def test_a_script_always_goes_through_the_card_even_a_harmless_one(paths, helper):
    asked = []
    c, runner = ctx(paths, helper, {("osascript",): RunResult([], 0, "Macintosh HD\n", "")}, gate=asked.append)
    assert call(c, "mac_script", {"script": SCRIPT}) == "Macintosh HD"
    assert asked == [{"app": "AppleScript", "to": ["script"], "cc": [], "subject": "script", "body": SCRIPT, "exibir": SCRIPT}]
    call(c, "mac_script", {"script": "Application('Finder').name()", "linguagem": "jxa"})
    assert asked[1]["app"] == "JXA" and runner.calls[-1][:4] == ["osascript", "-l", "JavaScript", "-e"]


def test_a_script_without_an_approval_channel_or_after_a_denial_never_runs(paths, helper):
    c, runner = ctx(paths, helper, {("osascript",): OK}, gate=None)
    with pytest.raises(Falha, match="aprovação"):
        call(c, "mac_script", {"script": SCRIPT})

    def deny(request):
        raise Refused("não enviei: o usuário negou o envio.")

    c, runner = ctx(paths, helper, {("osascript",): OK}, gate=deny)
    with pytest.raises(Falha, match="negou"):
        call(c, "mac_script", {"script": SCRIPT})
    assert runner.calls == []


def test_the_card_shows_the_whole_script_with_control_characters_escaped(paths, helper):
    asked = []
    nasty = 'display dialog "oi"\x1b[2J‮\x00 fim\r\n\tok'
    c, _ = ctx(paths, helper, {("osascript",): OK}, gate=asked.append)
    call(c, "mac_script", {"script": nasty})
    shown = asked[0]["exibir"]
    assert "\x1b" not in shown and "\x00" not in shown and "‮" not in shown and "\r" not in shown
    assert "\\u{001b}" in shown and "\\u{202e}" in shown and "\\u{0000}" in shown and "\\u{000d}" in shown
    assert "\n\tok" in shown and shown.startswith('display dialog "oi"')


def test_the_mac_script_tool_has_no_regex_deciding_a_script_is_safe(paths, helper):
    asked = []
    c, _ = ctx(paths, helper, {("osascript",): OK}, gate=asked.append)
    for script in ('tell application "System Events" to keystroke "d" using {command down, shift down}', "Application('System Events').keyCode(36)",
                   'tell application "System Events" to click button "Send" of window 1'):
        call(c, "mac_script", {"script": script})
    assert len(asked) == 3


@pytest.mark.parametrize("script", [
    'do shell script "security find-generic-password -s foo -w"',
    'do shell script "security dump-keychain -d login.keychain"',
    'do shell script "cat ~/Library/Keychains/login.keychain-db"',
    'do shell script "cat ~/.ssh/id_ed25519"',
    'set k to do shell script "security find-internet-password -s github.com"',
    "Application('System Events').doShellScript('security find-generic-password -a me')",
    'display dialog "sk-' + "a" * 30 + '"',
    'do shell script "cat ~/.config/wisp/secrets/telegram-token"',
])
def test_a_script_that_touches_secrets_is_refused_outright_before_any_card(paths, helper, script):
    asked = []
    c, runner = ctx(paths, helper, {("osascript",): OK}, gate=asked.append)
    with pytest.raises(Falha, match="senhas|segredo|Recusei"):
        call(c, "mac_script", {"script": script})
    assert asked == [] and runner.calls == []


@pytest.mark.parametrize("script", [
    'tell application "Finder" to empty the trash',
    'do shell script "rm -rf ~/Documents"',
    'tell application "Mail" to send m',
])
def test_destructive_and_mail_sending_scripts_are_still_refused_before_the_card(paths, helper, script):
    asked = []
    c, runner = ctx(paths, helper, {("osascript",): OK}, gate=asked.append)
    with pytest.raises(Falha, match="Recusei"):
        call(c, "mac_script", {"script": script})
    assert asked == [] and runner.calls == []


def test_a_script_denied_by_macos_names_the_permission(paths, helper):
    c, _ = ctx(paths, helper, {("osascript",): RunResult([], 1, "", "Not authorized to send Apple events (-1743)")}, gate=lambda r: None)
    with pytest.raises(Falha, match="Automação"):
        call(c, "mac_script", {"script": 'tell application "Notes" to get name of notes'})
    c, _ = ctx(paths, helper, gate=lambda r: None)
    with pytest.raises(Falha, match="linguagem"):
        call(c, "mac_script", {"script": "x", "linguagem": "perl"})


def test_a_script_through_mac_send_needs_its_own_subject_and_language(paths, helper):
    c, _ = ctx(paths, helper, {("osascript",): OK}, gate=lambda r: None)
    base = {"app": "AppleScript", "to": ["script"], "subject": "script", "body": SCRIPT, "acao": "script"}
    assert call(c, "mac_send", base) == "Script executado."
    for over in ({"subject": "x"}, {"app": "Safari"}):
        with pytest.raises(Falha):
            call(c, "mac_send", {**base, **over})


def test_shortcuts_run_directly_only_when_on_the_app_setting_list_and_without_send_words(paths, helper):
    script = with_settings({("shortcuts",): RunResult([], 0, "feito\n", "")}, macReadOnlyShortcuts=["Modo Foco", "Enviar relatório"])
    c, runner = ctx(paths, helper, script)
    assert call(c, "mac_shortcut", {"nome": "Modo Foco", "entrada": "25"}) == "feito"
    shortcut_call = next(x for x in runner.calls if x[0] == "shortcuts")
    assert shortcut_call[:3] == ["shortcuts", "run", "Modo Foco"] and shortcut_call[3] == "--input-path" and not Path(shortcut_call[4]).exists()
    for nome in ("Enviar relatório", "Send to Ana", "Mandar mensagem", "Email para o chefe", "Qualquer coisa"):
        with pytest.raises(Falha, match="mac_send"):
            call(c, "mac_shortcut", {"nome": nome})
    with pytest.raises(Falha):
        call(c, "mac_shortcut", {"nome": " "})
    assert sum(1 for x in runner.calls if x[0] == "shortcuts") == 1


def test_a_shortcut_goes_through_the_card_and_runs_only_after_the_allow(paths, helper):
    asked = []
    c, runner = ctx(paths, helper, {("shortcuts",): RunResult([], 0, "", "")}, gate=asked.append)
    args = {"app": "Atalhos", "to": ["Enviar relatório"], "subject": "atalho", "body": "semana 47", "acao": "atalho"}
    assert call(c, "mac_send", args) == "enviado"
    assert asked == [{"app": "Atalhos", "to": ["Enviar relatório"], "cc": [], "subject": "atalho", "body": "semana 47"}]
    assert runner.calls[0][:3] == ["shortcuts", "run", "Enviar relatório"]

    def deny(request):
        raise Refused("não enviei: o usuário negou o envio.")

    c, runner = ctx(paths, helper, {("shortcuts",): OK}, gate=deny)
    with pytest.raises(Falha, match="negou"):
        call(c, "mac_send", args)
    assert runner.calls == []


def test_read_only_tools_are_exactly_the_ones_that_change_nothing():
    assert mac_control.READ_ONLY == {"mac_apps", "mac_windows", "mac_ui_tree", "mac_battery", "mac_wifi", "mac_dnd_status",
                                     "mac_screenshot", "mac_shortcuts_list"}
    assert mac_control.ALWAYS_ASK == {"mac_send", "mac_script"}
    for tool in mac_control.TOOLS.values():
        assert set(tool.required) <= set(tool.properties) and tool.name.startswith("mac_")




def test_the_log_is_private_and_the_script_the_tree_and_the_screenshot_are_never_stored(paths, helper):
    asked = []
    secret_script = 'display dialog "conteudo secreto do script"'
    tree = helper_result(helper, ["arvore", "--max", "400", "--profundidade", "8"], out='[0] AXTextArea value="texto secreto da tela"')
    c, _ = ctx(paths, helper, {**tree, ("osascript",): RunResult([], 0, "saida secreta", "")}, gate=asked.append)
    call(c, "mac_script", {"script": secret_script})
    call(c, "mac_ui_tree", {})
    windows = json.dumps([{"id": 4, "app": "Safari", "titulo": "", "largura": 8, "altura": 8}])

    def runner_run(argv, **kw):
        if argv[0] == "screencapture":
            Path(argv[-1]).write_bytes(b"png")
            return OK
        return RunResult(list(argv), 0, windows, "")

    c.runner.run = runner_run
    call(c, "mac_screenshot", {"app": "Safari"})
    log = paths.state / mac_control.LOG_NAME
    text = log.read_text()
    assert "secret" not in text and "capturas" not in text
    rows = [json.loads(x) for x in text.splitlines() if json.loads(x)["fase"] == "feito"]
    assert [r["resultado"] for r in rows] == [f"<{len('saida secreta')} caracteres>", f"<{len(chr(10).join(['[0] AXTextArea value=' + chr(34) + 'texto secreto da tela' + chr(34)]))} caracteres>", rows[2]["resultado"]]
    assert rows[2]["resultado"].startswith("<") and rows[2]["resultado"].endswith("caracteres>")
    assert oct(log.stat().st_mode & 0o777) == "0o600" and oct(paths.state.stat().st_mode & 0o777) == "0o700"


def test_mac_send_and_shortcut_inputs_are_redacted_in_the_log(paths, helper):
    c, _ = ctx(paths, helper, {**window(helper), ("shortcuts",): RunResult([], 0, "saída secreta", "")}, gate=lambda r: None)
    call(c, "mac_send", send_args(subject=""))
    call(c, "mac_send", {"app": "Atalhos", "to": ["Meu atalho"], "subject": "atalho", "body": "entrada secreta", "acao": "atalho"})
    text = (paths.state / mac_control.LOG_NAME).read_text()
    assert "secret" not in text and "chego" not in text and "Ana" not in text and "Meu atalho" not in text
    assert '"body": "<' in text and '"to": "<' in text


TRUSTED_DENY = ["Write(~/Library/Preferences/ai.wisp.app.plist)", "Edit(~/Library/Preferences/ai.wisp.app.plist)", "Write(~/.config/wisp/**)",
                "Edit(~/.config/wisp/**)", "Write(~/.local/state/wisp/mac-callers/**)", "Edit(~/.local/state/wisp/mac-callers/**)", "Bash(*defaults*ai.wisp.app*)", "Bash(*Preferences/ai.wisp.app*)", "Bash(*ai.wisp.app.plist*)"]


def test_the_agent_is_denied_write_edit_and_defaults_on_every_path_the_cli_trusts():
    from wisp.paths import resources_root
    from wisp_bot import claude_runner

    harness = json.loads((resources_root() / "harness/settings.json").read_text())["permissions"]["deny"]
    shipped = json.loads((Path(__file__).parent / "fixtures/contract/guard-settings.json").read_text())["permissions"]["deny"]
    for source in (harness, shipped, claude_runner.DENY_RULES, claude_runner.guard_settings("/w")["permissions"]["deny"]):
        for rule in TRUSTED_DENY:
            assert rule in source, rule


def test_mac_send_builds_the_card_from_the_window_and_the_helper_presses_send_in_the_same_process(paths, helper):
    asked = []
    c, runner = ctx(paths, helper, window(helper), gate=asked.append)
    assert call(c, "mac_send", send_args()) == "enviado"
    assert asked == [{"app": "Messages", "to": ["Ana Souza"], "cc": [], "subject": "", "body": BODY}]
    last = helper_calls(runner, helper)[-1]
    assert last[:5] == ["enviar-janela", "--app", "Messages", "--regex", mac_control.SEND_PATTERN] and last[5] == "--esperado"
    assert json.loads(last[6]) == {"corpo": BODY, "destinatarios": ["Ana Souza"], "cc": [], "assunto": ""}
    assert all(x[0] != "clicar" for x in helper_calls(runner, helper)), "no separate click process after the last read"
    assert sum(1 for x in helper_calls(runner, helper) if x[0] == "composicao") == 1


@pytest.mark.parametrize("stderr", ["recusei: a janela da mensagem mudou depois da aprovação (corpo, destinatários, cópias ou assunto) ou há cópia oculta",
                                    "recusei: não achei exatamente um botão de enviar dentro da janela da mensagem"])
def test_when_the_helper_refuses_inside_its_own_process_nothing_is_reported_as_sent(paths, helper, stderr):
    script = {**window(helper), (helper, "enviar-janela"): RunResult([], 6, "", stderr)}
    c, _ = ctx(paths, helper, script, gate=lambda r: None)
    with pytest.raises(Falha, match="Recusei"):
        call(c, "mac_send", send_args())


def test_the_cc_must_equal_the_request_and_a_bcc_refuses(paths, helper):
    asked = []
    c, runner = ctx(paths, helper, window(helper, app="Mail", destinatarios=("ana@x.com",), cc=("carla@x.com",)), gate=asked.append)
    with pytest.raises(Falha, match="Cc"):
        call(c, "mac_send", send_args(app="Mail", to=["ana@x.com"]))
    with pytest.raises(Falha, match="Cc"):
        call(c, "mac_send", send_args(app="Mail", to=["ana@x.com"], cc=["outra@x.com"]))
    assert call(c, "mac_send", send_args(app="Mail", to=["ana@x.com"], cc=["carla@x.com"])) == "enviado"
    assert asked == [{"app": "Mail", "to": ["ana@x.com"], "cc": ["carla@x.com"], "subject": "", "body": BODY}]
    c, runner = ctx(paths, helper, window(helper, app="Mail", destinatarios=("ana@x.com",), bcc=("evil@y.com",)), gate=asked.append)
    with pytest.raises(Falha, match="Bcc"):
        call(c, "mac_send", send_args(app="Mail", to=["ana@x.com"]))
    assert len(asked) == 1


def test_a_body_that_cannot_be_identified_refuses(paths, helper):
    asked = []
    c, runner = ctx(paths, helper, window(helper, corpo=""), gate=asked.append)
    with pytest.raises(Falha, match="identificar o campo do corpo"):
        call(c, "mac_send", send_args())
    assert asked == [] and all(x[0] != "enviar-janela" for x in helper_calls(runner, helper))






@pytest.mark.parametrize("title", ["发送", "送信", "Отправить", "Invia", "Wyślij", "Verstuur", "Répondre", "Skicka", "Senden", "Envoyer", "发送邮件",
                                   "send_button", "SendButton", "sendButton", "btn-send", "composer.send"])
def test_more_languages_and_camel_or_snake_identifiers_count_as_send(title):
    assert mac_control.send_title(title)


@pytest.mark.parametrize("title", ["Sender", "resend", "Sentinel", "backButton", "Cancelar", "Imprimir"])
def test_lookalikes_are_not_send(title):
    assert not mac_control.send_title(title)






def test_every_menu_outside_the_safe_apps_needs_the_card_and_inside_them_the_helper_blocks_send_titles(paths, helper):
    c, runner = ctx(paths, helper, {(helper, "foco"): info("Mail"), (helper, "menu"): OK})
    for path in ("Mensagem > Enviar", "Mensagem > Sen", "Arquivo > Imprimir"):
        with pytest.raises(Falha, match="mac_send"):
            call(c, "mac_ui_menu", {"caminho": path})
    assert all(x[0] != "menu" for x in helper_calls(runner, helper))
    c, runner = ctx(paths, helper, {(helper, "foco"): info("Finder"), (helper, "menu"): OK})
    call(c, "mac_ui_menu", {"caminho": "Arquivo > Sen"})
    assert helper_calls(runner, helper)[-1] == ["menu", "Arquivo > Sen", "--bloquear", mac_control.SEND_PATTERN]


def test_a_menu_through_the_card_resolves_the_real_title_exactly_first(paths, helper):
    asked = []
    real = RunResult([], 0, json.dumps({"menu": "Mensagem > Enviar", "titulo": "Enviar"}), "")
    script = {(helper, "foco"): info("Mail"), (helper, "menu", "Mensagem > Enviar", "--exato", "--resolver"): real, (helper, "menu"): OK,
              (helper, "menu", "Mensagem > Sen", "--exato", "--resolver"): RunResult([], 1, "", "não achei o item de menu")}
    args = {"app": "Mail", "to": ["Mensagem > Enviar"], "subject": "menu", "body": "Mensagem > Enviar", "acao": "menu"}
    c, runner = ctx(paths, helper, script, gate=asked.append)
    assert call(c, "mac_send", args) == "feito"
    assert asked and helper_calls(runner, helper)[-1] == ["menu", "Mensagem > Enviar", "--exato", "--app", "Mail"]
    asked.clear()
    with pytest.raises(Falha):
        call(c, "mac_send", {**args, "to": ["Mensagem > Sen"], "body": "Mensagem > Sen"})
    assert asked == []


@pytest.mark.parametrize("url", [
    "mailto:ana@x.com?bcc=evil@y.com", "mailto:ana@x.com?cc=a@b.c", "mailto:ana@x.com?BCC=evil@y.com", "mailto:ana@x.com?subject=oi&body=texto",
    "mailto:ana@x.com?to=evil@y.com", "mailto:ana@x.com?Body=x", "mailto:ana@x.com&bcc=evil@y.com",
])
def test_mac_open_refuses_a_mailto_that_hides_recipients_or_text(paths, helper, url):
    c, runner = ctx(paths, helper, {("open",): OK})
    with pytest.raises(Falha, match="mailto"):
        call(c, "mac_open", {"alvo": url})
    assert runner.calls == []


@pytest.mark.parametrize("url", ["mailto:ana@x.com", "mailto:ana@x.com?subject=Oi", "https://exemplo.com/?cc=1&bcc=2"])
def test_a_plain_mailto_and_an_ordinary_url_still_open(paths, helper, url):
    c, runner = ctx(paths, helper, {("open",): OK})
    call(c, "mac_open", {"alvo": url})
    assert runner.calls == [["open", url]]


def test_the_helper_gets_the_nonce_on_stdin_and_the_server_wrote_a_private_file_for_it(paths, helper):
    seen = []
    c = Ctx(FakeRunner(), paths, test_helper=Path(helper))
    c.runner.run = lambda argv, **kw: (seen.append(kw), RunResult(list(argv), 0, "{}", ""))[1]
    c.helper_run("apps")
    assert seen[0]["stdin"] == (c.nonce + "\n").encode() and len(c.nonce) == 32 and int(c.nonce, 16) >= 0
    assert not (seen[0].get("env") or {}).get("WISP_MAC_CALLER")
    marker = paths.state / mac_control.CALLERS_DIR / c.nonce
    assert marker.is_file() and oct(marker.stat().st_mode & 0o777) == "0o600" and oct(marker.parent.stat().st_mode & 0o777) == "0o700"
    other = Ctx(FakeRunner(), paths, test_helper=Path(helper))
    assert other.nonce != c.nonce and not (marker.parent / other.nonce).exists()
    c.helper_run("apps")
    assert len(list(marker.parent.iterdir())) == 1


def test_stale_caller_files_are_removed_when_a_new_server_registers(paths, helper):
    folder = paths.state / mac_control.CALLERS_DIR
    folder.mkdir(parents=True, exist_ok=True)
    old = folder / ("a" * 32)
    old.write_text("1")
    os.utime(old, (1, 1))
    c, _ = ctx(paths, helper, {(helper,): RunResult([], 0, "{}", "")})
    c.helper_run("apps")
    assert not old.exists() and (folder / c.nonce).exists()


NASTY = "ana‮@x.com​‍﻿⁦\x1b[2J\x00 fim"


def test_the_telegram_card_escapes_bidi_zero_width_and_control_characters_like_escape_controls():
    from wisp_bot import aprovacoes

    assert aprovacoes.escapar(NASTY) == mac_control.escape_controls(NASTY)
    for tool, engine in (("mcp__wisp-mac__mac_send", "codex"), ("mcp__wisp-mac__mac_send", None), ("Bash", None)):
        req = {"tool_name": tool, "input": {"command": NASTY, "to": [NASTY], "body": NASTY, "subject": ""}, **({"engine": engine} if engine else {})}
        card = aprovacoes.descrever(req)
        for text in (card["summary"], card["detail"]):
            assert not any(ch in text for ch in "‮​‍﻿⁦\x1b\x00"), (tool, text)
        assert "\\u{202e}" in card["detail"] and "\\u{200b}" in card["detail"]
    assert aprovacoes.escapar("linha 1\n\tação 日本 ✓") == "linha 1\n\tação 日本 ✓"


SAFE = ["Finder", "Preview", "System Settings", "Music", "Spotify", "Calculator", "Calendar", "Notes", "TextEdit", "Pages", "Numbers", "Keynote"]


@pytest.mark.parametrize("app", SAFE)
def test_return_newlines_and_other_keys_pass_without_a_card_only_in_the_safe_apps(paths, helper, app):
    script = {(helper, "foco"): info(app), (helper, "tecla"): OK, (helper, "digitar"): OK, (helper, "clicar"): RunResult([], 0, "{}", "")}
    c, runner = ctx(paths, helper, script)
    for combo in ("return", "ctrl+m", "ctrl+j", "ctrl+o", "space", "cmd+shift+d", "f5"):
        call(c, "mac_ui_key", {"tecla": combo})
    call(c, "mac_ui_type", {"texto": "a\nb"})
    call(c, "mac_ui_click", {"titulo": "Continuar", "app": app})
    assert "--estrito" not in helper_calls(runner, helper)[-1]
    assert sum(1 for x in helper_calls(runner, helper) if x[0] == "tecla") == 7


@pytest.mark.parametrize("combo", ["ctrl+m", "ctrl+j", "ctrl+o", "ctrl+M", "return", "enter", "cmd+return", "cmd+shift+d", "space", "f5", "alt+return",
                                   "ctrl+a", "cmd+shift+4", "cmd+option+i", "shift+return", "ctrl+shift+m"])
@pytest.mark.parametrize("app", ["Slack", "Mail", "Safari", "Notion", "Terminal"])
def test_outside_the_safe_apps_a_key_is_denied_unless_it_is_navigation_or_a_plain_cmd_letter(paths, helper, app, combo):
    c, runner = ctx(paths, helper, {(helper, "foco"): info(app), (helper, "tecla"): OK})
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_ui_key", {"tecla": combo})
    assert all(x[0] != "tecla" for x in helper_calls(runner, helper))


@pytest.mark.parametrize("combo", ["up", "down", "left", "right", "tab", "shift+tab", "esc", "escape", "delete", "backspace", "pageup", "pagedown",
                                   "home", "end", "cmd+t", "cmd+c", "cmd+v", "cmd+a", "cmd+5", "opt+left", "cmd+left", "shift+down"])
def test_navigation_keys_and_plain_cmd_letters_pass_outside_the_safe_apps(paths, helper, combo):
    c, runner = ctx(paths, helper, {(helper, "foco"): info("Slack"), (helper, "tecla"): OK})
    call(c, "mac_ui_key", {"tecla": combo})
    assert helper_calls(runner, helper)[-1][0] == "tecla"


@pytest.mark.parametrize("combo,expected", [("ctrl+m", False), ("ctrl+j", False), ("ctrl+o", False), ("cmd+return", False), ("cmd+shift+d", False),
                                            ("cmd+d", True), ("tab", True), ("pagedown", True), ("space", False), ("a", False), ("cmd+enter", False)])
def test_key_is_safe(combo, expected):
    assert key_is_safe(combo) is expected


def test_a_card_approved_key_press_runs_even_for_ctrl_m(paths, helper):
    asked = []
    c, runner = ctx(paths, helper, {(helper, "foco"): info("Slack"), (helper, "tecla"): OK}, gate=asked.append)
    args = {"app": "Slack", "to": ["ctrl+m"], "subject": "tecla", "body": "ctrl+m", "acao": "tecla"}
    assert call(c, "mac_send", args) == "feito" and len(asked) == 1
    assert helper_calls(runner, helper)[-1] == ["tecla", "ctrl+m", "--app", "Slack"]


@pytest.mark.parametrize("combo", ["space", "return"])
def test_a_focused_send_control_refuses_space_and_return_even_in_a_safe_app(paths, helper, combo):
    c, runner = ctx(paths, helper, {(helper, "foco"): info("Calendar", papel="AXButton", pressavel=True, titulo="Send"), (helper, "tecla"): OK})
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_ui_key", {"tecla": combo})
    c, runner = ctx(paths, helper, {(helper, "foco"): info("Calendar", papel="AXButton", pressavel=True, titulo="Cancelar"), (helper, "tecla"): OK})
    call(c, "mac_ui_key", {"tecla": combo})


NEVER_BUNDLES = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty",
                 "com.github.wez.wezterm", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.jetbrains.pycharm",
                 "com.jetbrains.intellij.ce", "com.apple.dt.Xcode", "com.apple.ScriptEditor2", "com.apple.Automator", "com.apple.shortcuts",
                 "com.raycast.macos", "org.hammerspoon.Hammerspoon", "com.stairways.keyboardmaestro.editor", "com.stairways.keyboardmaestro.engine",
                 "com.docker.docker", "dev.commandline.waveterm"]


@pytest.mark.parametrize("bundle", NEVER_BUNDLES)
def test_command_and_automation_apps_are_never_safe_by_bundle_id_whatever_their_name_or_the_user_setting(paths, helper, bundle):
    renamed = {(helper, "foco"): info("Notes", bundle=bundle), (helper, "digitar"): OK, (helper, "tecla"): OK}
    c, runner = ctx(paths, helper, with_settings(renamed, macSafeApps=[bundle, bundle.upper()]))
    assert not mac_control.safe_app(c, bundle, "Notes")
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_ui_type", {"texto": "rm -rf ~/x\n"})
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_ui_key", {"tecla": "return"})
    assert all(x[0] not in ("digitar", "tecla") for x in helper_calls(runner, helper))


def test_an_app_that_claims_a_safe_name_but_has_another_bundle_is_not_safe(paths, helper):
    c, runner = ctx(paths, helper, {(helper, "foco"): info("Finder", bundle="com.evil.fakefinder"), (helper, "digitar"): OK})
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_ui_type", {"texto": "a\nb"})


@pytest.mark.parametrize("bundle", ["", None])
def test_an_app_whose_bundle_cannot_be_read_needs_the_card(paths, helper, bundle):
    data = {"app": "Finder", "papel": "AXTextField", "seguro": False, **({} if bundle is None else {"bundle": bundle})}
    c, runner = ctx(paths, helper, {(helper, "foco"): RunResult([], 0, json.dumps(data), ""), (helper, "digitar"): OK})
    with pytest.raises(Falha, match="mac_send"):
        call(c, "mac_ui_type", {"texto": "a\nb"})


def test_the_safe_list_is_by_bundle_id_and_never_takes_browsers_or_messengers(paths, helper):
    script = with_settings({}, macSafeApps=["com.apple.Safari", "com.google.Chrome", "com.apple.mail", "net.whatsapp.WhatsApp", "notion.id"])
    c, _ = ctx(paths, helper, script)
    for bundle in ("com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.apple.mail", "net.whatsapp.WhatsApp", "company.thebrowser.Browser"):
        assert not mac_control.safe_app(c, bundle)
    assert mac_control.safe_app(c, "notion.id") and mac_control.safe_app(c, "COM.APPLE.FINDER") and not mac_control.safe_app(c, "Notion")
    assert all(mac_control.safe_app(c, b) for b in mac_control.DEFAULT_SAFE_BUNDLES)


def test_the_defaults_hold_no_command_or_code_runner():
    for bundle in mac_control.DEFAULT_SAFE_BUNDLES:
        assert not mac_control.bundle_matches(bundle, mac_control.NEVER_SAFE_BUNDLES, mac_control.NEVER_SAFE_PREFIXES), bundle


def test_the_safe_and_shortcut_lists_come_from_the_app_settings_and_a_malformed_setting_adds_nothing(paths, helper):
    paths.config.mkdir(parents=True, exist_ok=True)
    (paths.config / "mac-apps-seguros.json").write_text(json.dumps(["notion.id"]))
    c, runner = ctx(paths, helper)
    assert not mac_control.safe_app(c, "notion.id") and mac_control.shortcut_allowlist(c) == set()
    assert ["defaults", "export", "ai.wisp.app", "-"] in runner.calls
    c, _ = ctx(paths, helper, with_settings({}, macReadOnlyShortcuts=["Modo Foco"], macSafeApps=["notion.id"]))
    assert mac_control.safe_app(c, "notion.id") and mac_control.shortcut_allowlist(c) == {"Modo Foco"}
    c, _ = ctx(paths, helper, {("defaults", "export", "ai.wisp.app", "-"): RunResult([], 0, "not a plist", "")})
    assert not mac_control.safe_app(c, "notion.id")
    c, _ = ctx(paths, helper, with_settings({}, macSafeApps="notion.id"))
    assert not mac_control.safe_app(c, "notion.id")


@pytest.mark.parametrize("app", SAFE + ["Slack", "Safari", "Notion"])
def test_clicks_always_carry_the_send_pattern_and_only_non_safe_apps_get_the_strict_flag(paths, helper, app):
    plain = {(helper, "foco"): info(app), (helper, "clicar"): RunResult([], 0, "{}", "")}
    c, runner = ctx(paths, helper, plain)
    call(c, "mac_ui_click", {"titulo": "Enviar uma cópia", "app": app})
    last = helper_calls(runner, helper)[-1]
    assert "--bloquear" in last and last[last.index("--bloquear") + 1] == mac_control.SEND_PATTERN
    assert ("--estrito" in last) is (app not in SAFE)


def test_a_point_click_always_carries_the_send_pattern_and_the_strict_flag_follows_the_owner_app(paths, helper):
    for owner, strict in (("Calendar", False), ("Slack", True)):
        resolved = json.dumps({"papel": "AXImage", "app": owner})
        script = {(helper, "clicar", "--ponto", "1,2", "--resolver"): RunResult([], 0, resolved, ""), (helper, "foco"): info(owner),
                  (helper, "clicar", "--ponto", "1,2"): RunResult([], 0, "{}", "")}
        c, runner = ctx(paths, helper, script)
        call(c, "mac_ui_click", {"ponto": "1,2"})
        last = helper_calls(runner, helper)[-1]
        assert last[:3] == ["clicar", "--ponto", "1,2"] and "--bloquear" in last and ("--estrito" in last) is strict


def test_the_server_pid_is_stored_in_the_nonce_file_and_a_sigterm_removes_it(paths, helper):
    import signal
    import subprocess
    import sys
    import textwrap

    c = Ctx(FakeRunner(), paths, test_helper=Path(helper))
    c.runner.run = lambda argv, **kw: RunResult(list(argv), 0, "{}", "")
    c.helper_run("apps")
    assert (paths.state / mac_control.CALLERS_DIR / c.nonce).read_text() == str(os.getpid())
    script = textwrap.dedent('''
        import os, sys, time
        from pathlib import Path
        from wisp import mac_control
        from wisp.paths import WispPaths
        from wisp.runner import FakeRunner, RunResult
        paths = WispPaths.for_os("Darwin", Path(sys.argv[1]), {})
        c = mac_control.Ctx(FakeRunner(), paths, test_helper=Path(sys.argv[2]))
        c.runner.run = lambda argv, **kw: RunResult(list(argv), 0, "{}", "")
        c.helper_run("apps")
        print(c.nonce, flush=True)
        time.sleep(30)
    ''')
    child = subprocess.Popen([sys.executable, "-c", script, str(paths.home), helper], stdout=subprocess.PIPE, text=True)
    nonce = child.stdout.readline().strip()
    marker = paths.state / mac_control.CALLERS_DIR / nonce
    assert marker.read_text() == str(child.pid)
    child.send_signal(signal.SIGTERM)
    child.wait(timeout=10)
    assert child.returncode == -signal.SIGTERM and not marker.exists()


VECTOR = json.loads((Path(__file__).parent / "fixtures/contract/escape-vector.json").read_text())


@pytest.mark.parametrize("case", VECTOR, ids=[c["name"] for c in VECTOR])
def test_the_shared_escape_vector_holds_for_the_cli_and_the_bot(case):
    from wisp_bot import aprovacoes

    assert mac_control.escape_controls(case["input"]) == case["expected"] == aprovacoes.escapar(case["input"])
