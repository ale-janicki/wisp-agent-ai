from __future__ import annotations

import json
import os
import plistlib
import re
import secrets
import shlex
import shutil
import tempfile
import time
import unicodedata
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import quote_plus, urlparse

from wisp.config import WispConfig, load_config
from wisp.guard_destructive import hook_guard_destructive
from wisp.guard_outbound import hook_guard_outbound
from wisp.hooks import hook_guard_secrets
from wisp.secrets_scan import scan_text
from wisp.mac import NEGADO, OSASCRIPT_S, SEM_AUTOMACAO, Falha, _app_instalado, _osascript, abrir, bateria, nao_perturbe, notificar, print_tela, volume
from wisp.paths import WispPaths
from wisp.runner import Runner
from wisp.send_gate import Gate, Refused

HELPER = "wisp-mac"
HELPER_IN_APP = Path("Contents/Helpers") / HELPER
APP_ROOTS = (Path("/Applications"),)
SETTINGS_DOMAIN = "ai.wisp.app"
SAFE_APPS_KEY = "macSafeApps"
SHORTCUTS_KEY = "macReadOnlyShortcuts"
CALLER_ENV = "WISP_MAC_CALLER"
DEFAULT_SAFE_APPS = ("finder", "preview", "system settings", "music", "spotify", "calculator", "calendar", "notes", "textedit", "pages",
                     "numbers", "keynote", "xcode", "terminal", "iterm", "iterm2")
ACOES = ("tecla", "texto", "clique", "script", "atalho")
HELPER_S = 30
LOG_NAME = "mac-acoes.jsonl"
LOG_LIMIT = 5_000_000
LOG_FIELD = 300
TREE_MAX = 1500
EXIT_BLOCKED = 5

ASSINATURA = ("Recusei: o ajudante wisp-mac não tem a mesma assinatura do Wisp.app, então não o executo. Reinstale ou atualize o Wisp.")
ATALHO_ENVIA = ("Recusei: um atalho pode enviar algo e não consigo ler as ações dele. Para rodá-lo use mac_send com app=Atalhos, acao=atalho, "
                "to=[nome do atalho], subject=atalho, body=o texto de entrada (ou o próprio nome), que pede a aprovação do usuário.")
FOCO_ILEGIVEL = "Recusei: não consegui ver qual campo está em foco, então não digito nada."
SEM_AJUDANTE = ("não achei o ajudante de controle do Mac (wisp-mac) dentro do Wisp.app; abra o app Wisp, instale ou atualize o Wisp "
                "e tente de novo")
SO_NO_MAC = "o controle do Mac só existe no macOS"
SEM_ACESSIBILIDADE = ("Sem permissão de Acessibilidade. Abra o Wisp > Ajustes > Controle do Mac e permita; depois peça de novo.")
SENHA = "Recusei: o campo em foco é de senha, o Wisp nunca digita em campo de senha."
ENVIO_DIRETO = ("Recusei: isso pode enviar ou confirmar algo e este app não está na lista de apps seguros. O usuário precisa aprovar: use mac_send com "
                "acao=tecla (to=[tecla], subject=tecla, body=tecla), acao=texto (to=[app], subject=texto, body=o texto), "
                "acao=clique (to=[rótulo], subject=clique, body=rótulo) ou, para enviar uma mensagem escrita na janela, sem acao.")
NAO_MENSAGEIRO = "mac_send sem acao só vale para apps de mensagem ou webmail no navegador (Mail, Mensagens, WhatsApp, Slack, Telegram, Outlook, Gmail…)."
SEGREDO = "Recusei: o script mexe em senhas, chaves ou no chaveiro do usuário."
ACAO_SUBJECT = "Para a ação {acao} o assunto precisa ser exatamente {acao}."
JANELA_MUDOU = "Não enviei: a janela mudou depois da aprovação."
SECRET_COMMAND = re.compile(r"security\s+(find|dump|export|add|delete|import)-|find-(generic|internet)-password|dump-keychain|library/keychains|\.keychain|\.ssh/|id_rsa|id_ed25519", re.I)

MENSAGEIROS = ("mail", "messages", "mensagens", "whatsapp", "slack", "telegram", "signal", "discord", "outlook", "teams",
               "thunderbird", "spark", "zoom", "skype", "messenger")
NAVEGADORES = re.compile(r"\b(safari|chrome|firefox|arc|brave|edge|opera|vivaldi|orion)\b")
WEBMAIL = re.compile(r"mail\.google\.com|outlook\.live\.com|outlook\.office(365)?\.com|office\.com|web\.whatsapp\.com|messenger\.com|"
                     r"web\.telegram\.org|discord\.com|app\.slack\.com|teams\.microsoft\.com|teams\.live\.com|"
                     r"gmail|whatsapp|outlook|messenger|telegram|discord|slack|teams", re.I)
ATALHOS_APP = ("atalhos", "shortcuts")
SHORTCUT_SENDS = re.compile(r"send|enviar|envia|message|mensagem|e-?mail|sms|imessage|mail", re.I)
SEND_PATTERN = r"\b(send|enviar|envia|mandar|senden|envoyer|submit|post|publicar|responder|reply)\b"
SEND_TITLE = re.compile(SEND_PATTERN, re.I)
SHELL_IN_SCRIPT = re.compile(r"do shell script\s+\"((?:[^\"\\]|\\.)*)\"|doShellScript\(\s*[\"']((?:[^\"'\\]|\\.)*)[\"']", re.I)
SEND_KEYS = {"return", "enter"}
SEND_MAIL_COMBO = ({"cmd", "shift"}, "d")
MODIFIERS = {"command": "cmd", "cmd": "cmd", "shift": "shift", "option": "opt", "opt": "opt", "alt": "opt", "control": "ctrl", "ctrl": "ctrl", "fn": "fn"}

SITES: dict[str, tuple[str, str | None]] = {
    "youtube": ("https://www.youtube.com", "https://www.youtube.com/results?search_query={q}"),
    "google": ("https://www.google.com", "https://www.google.com/search?q={q}"),
    "maps": ("https://www.google.com/maps", "https://www.google.com/maps/search/{q}"),
    "wikipedia": ("https://pt.wikipedia.org", "https://pt.wikipedia.org/w/index.php?search={q}"),
    "github": ("https://github.com", "https://github.com/search?q={q}"),
    "gmail": ("https://mail.google.com", "https://mail.google.com/mail/u/0/#search/{q}"),
    "whatsapp": ("https://web.whatsapp.com", None),
    "spotify": ("https://open.spotify.com", "https://open.spotify.com/search/{q}"),
    "netflix": ("https://www.netflix.com", "https://www.netflix.com/search?q={q}"),
    "amazon": ("https://www.amazon.com.br", "https://www.amazon.com.br/s?k={q}"),
}
SITE_ALIASES = {"yt": "youtube", "you tube": "youtube", "mapas": "maps", "google maps": "maps", "gmaps": "maps", "wiki": "wikipedia",
                "zap": "whatsapp", "whatsapp web": "whatsapp", "email": "gmail", "pesquisa": "google", "busca": "google"}
BROWSERS = {"chrome": "Google Chrome", "google chrome": "Google Chrome", "edge": "Microsoft Edge", "brave": "Brave Browser",
            "firefox": "Firefox", "safari": "Safari", "arc": "Arc", "opera": "Opera", "vivaldi": "Vivaldi"}
PANES = {
    "acessibilidade": "com.apple.preference.security?Privacy_Accessibility",
    "automacao": "com.apple.preference.security?Privacy_Automation",
    "gravacao-de-tela": "com.apple.preference.security?Privacy_ScreenCapture",
    "privacidade": "com.apple.preference.security",
    "wifi": "com.apple.wifi-settings-extension",
    "rede": "com.apple.Network-Settings.extension",
    "bluetooth": "com.apple.BluetoothSettings",
    "som": "com.apple.Sound-Settings.extension",
    "monitores": "com.apple.Displays-Settings.extension",
    "bateria": "com.apple.Battery-Settings.extension",
    "notificacoes": "com.apple.Notifications-Settings.extension",
    "teclado": "com.apple.Keyboard-Settings.extension",
    "foco": "com.apple.Focus-Settings.extension",
    "geral": "com.apple.systempreferences.GeneralSettings",
    "aparencia": "com.apple.Appearance-Settings.extension",
}
SETTINGS_SCHEME = "x-apple.systempreferences:"
MEDIA_APPS = {"music": "Music", "musica": "Music", "spotify": "Spotify"}
MEDIA_COMMANDS = {"tocar": "play", "pausar": "pause", "alternar": "playpause", "proxima": "next track", "anterior": "previous track"}
DARK_MODES = {"escuro": "true", "claro": "false", "alternar": "not dark mode"}
BRIGHTNESS_KEYS = {"mais": 144, "menos": 145}
BRIGHTNESS_STEPS = 3


def fold(text: str) -> str:
    return unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().casefold().strip()


def is_messenger(app: str | None) -> bool:
    name = fold(app or "")
    return bool(name) and any(part in name for part in MENSAGEIROS)


def is_browser(app: str | None) -> bool:
    return bool(NAVEGADORES.search(fold(app or "")))


def sensitive(info: dict) -> bool:
    app = str(info.get("app") or "")
    if is_messenger(app):
        return True
    return is_browser(app) and bool(WEBMAIL.search(f"{info.get('documento') or ''} {info.get('janela') or ''}"))


def send_title(text: str) -> bool:
    return bool(SEND_TITLE.search(text))


def key_sends(combo: str) -> bool:
    tokens = [MODIFIERS.get(t.strip(), t.strip()) for t in combo.lower().split("+")]
    key, mods = tokens[-1], set(tokens[:-1])
    return key in SEND_KEYS or (key == SEND_MAIL_COMBO[1] and mods == SEND_MAIL_COMBO[0])


def canon(text: str) -> str:
    return unicodedata.normalize("NFC", text).replace("\r\n", "\n").replace("\r", "\n").strip()


def escape_controls(text: str) -> str:
    out = []
    for ch in text:
        if ch in "\n\t" or not unicodedata.category(ch).startswith("C"):
            out.append(ch)
        else:
            out.append(f"\\u{{{ord(ch):04x}}}")
    return "".join(out)


def url_intent(site: str | None = None, query: str | None = None, url: str | None = None) -> str:
    if url:
        parts = urlparse(url.strip())
        if parts.scheme.lower() not in ("http", "https") or not parts.netloc:
            raise Falha("Só abro endereços http ou https.")
        return url.strip()
    if not site and not query:
        raise Falha("Diga o endereço, ou o site (e o que buscar).")
    key = fold(site or "")
    key = re.sub(r"^(https?://)?(www\.)?", "", key).rstrip("/")
    key = SITE_ALIASES.get(key, re.sub(r"\.com(\.br)?$", "", key))
    key = SITE_ALIASES.get(key, key)
    if key in SITES:
        home, search = SITES[key]
        return search.format(q=quote_plus(query.strip())) if query and query.strip() and search else home
    if site and re.fullmatch(r"[\w-]+(\.[\w-]+)+(/\S*)?", site.strip()):
        return "https://" + re.sub(r"^https?://", "", site.strip())
    terms = " ".join(part for part in (site, query) if part and part.strip())
    return SITES["google"][1].format(q=quote_plus(terms))


def parse_combo(combo: str) -> str:
    text = combo.strip()
    if not text or text.endswith("+") and text != "+":
        raise Falha("Informe a tecla, como cmd+shift+4 ou return.")
    return text


@dataclass
class Ctx:
    runner: Runner
    paths: WispPaths
    system: str = "Darwin"
    gate: Gate | None = None
    cfg: WispConfig | None = None
    test_helper: Path | None = None
    verified: dict = field(default_factory=dict)
    nonce: str = field(default_factory=lambda: secrets.token_hex(16))
    settings_cache: dict = field(default_factory=dict)

    def candidates(self) -> list[Path]:
        bundles = [p for p in Path(__file__).resolve().parents if p.suffix == ".app"][:1]
        roots = [*bundles, *(root / "Wisp.app" for root in APP_ROOTS), self.paths.home / "Applications" / "Wisp.app"]
        return [root / HELPER_IN_APP for root in roots]

    def requirement(self, app: Path) -> str:
        shown = self.runner.run(["codesign", "-dvv", str(app)], timeout=OSASCRIPT_S)
        team = re.search(r"TeamIdentifier=([A-Z0-9]{10})", shown.stderr + shown.stdout)
        if team:
            return f'anchor apple generic and certificate leaf[subject.OU] = "{team.group(1)}"'
        rule = self.runner.run(["codesign", "-d", "-r-", str(app)], timeout=OSASCRIPT_S)
        leaf = re.search(r'certificate leaf = H"([0-9a-fA-F]{40})"', rule.stderr + rule.stdout)
        if leaf:
            return f'certificate leaf = H"{leaf.group(1)}"'
        raise Falha(ASSINATURA)

    def verify(self, helper: Path) -> None:
        key = (str(helper), helper.stat().st_mtime_ns)
        if key in self.verified:
            return
        requirement = self.requirement(helper.parents[2])
        checked = self.runner.run(["codesign", "--verify", "--strict", "-R=" + requirement, str(helper)], timeout=OSASCRIPT_S)
        if checked.exit != 0:
            raise Falha(ASSINATURA)
        self.verified[key] = True

    def helper(self) -> Path:
        if self.system != "Darwin":
            raise Falha(SO_NO_MAC)
        if self.test_helper is not None:
            return self.test_helper
        path = next((p for p in self.candidates() if p.is_file() and os.access(p, os.X_OK)), None)
        if path is None:
            raise Falha(SEM_AJUDANTE)
        self.verify(path)
        return path

    def helper_run(self, *args: str) -> str:
        r = self.runner.run([str(self.helper()), *args], timeout=HELPER_S, env={**os.environ, CALLER_ENV: self.nonce})
        if r.timed_out:
            raise Falha("O Mac demorou demais para responder. Tente de novo.")
        if r.exit == 3:
            raise Falha(SEM_ACESSIBILIDADE)
        if r.exit != 0:
            text = r.stderr.strip()
            raise Falha(text[0].upper() + text[1:] if text else "O Mac não conseguiu fazer isso agora.")
        return r.stdout.strip()

    def helper_json(self, *args: str):
        try:
            return json.loads(self.helper_run(*args))
        except ValueError:
            raise Falha("O ajudante do Mac respondeu algo que não entendi.") from None

    def settings(self) -> WispConfig:
        if self.cfg is None:
            try:
                self.cfg = load_config()
            except (ValueError, TypeError, OSError):
                self.cfg = WispConfig()
        return self.cfg


def focus_info(ctx: Ctx, app: str | None = None) -> dict:
    info = ctx.helper_json("foco", *(["--app", app] if app else []))
    if not isinstance(info, dict):
        raise Falha(FOCO_ILEGIVEL)
    return info


def abrir_url(ctx: Ctx, url: str | None = None, site: str | None = None, busca: str | None = None, navegador: str | None = None) -> str:
    alvo = url_intent(site, busca, url)
    if navegador:
        nome = BROWSERS.get(fold(navegador), navegador)
        app = _app_instalado(nome)
        if app is None:
            raise Falha(f"Não achei o navegador {navegador} instalado.")
        argv = ["open", "-a", str(app), alvo]
    else:
        argv = ["open", alvo]
    r = ctx.runner.run(argv, timeout=OSASCRIPT_S)
    if r.timed_out or r.exit != 0:
        raise Falha(f"Não consegui abrir {alvo}.")
    return f"Abri {alvo}" + (f" no {navegador}." if navegador else ".")


def app_acao(ctx: Ctx, acao: str, app: str) -> str:
    comando = {"focar": "ativar", "esconder": "esconder", "sair": "sair"}.get(acao)
    if comando is None:
        raise Falha("A ação do app é focar, esconder ou sair.")
    ctx.helper_run(comando, "--app", app)
    return {"focar": f"Trouxe {app} para a frente.", "esconder": f"Escondi {app}.", "sair": f"Pedi para {app} fechar."}[acao]


def apps(ctx: Ctx) -> str:
    lista = ctx.helper_json("apps")
    if not lista:
        return "Nenhum app aberto."
    return "\n".join(f"- {a['nome']}" + (" (na frente)" if a.get("ativo") else "") + (" (escondido)" if a.get("oculto") else "") for a in lista)


def janelas(ctx: Ctx, app: str | None = None) -> str:
    lista = ctx.helper_json("janelas", *(["--app", app] if app else []))
    if not lista:
        return "Nenhuma janela aberta."
    return "\n".join(f"- {j['app']}: {j['titulo'] or '(sem título)'} ({j['largura']}x{j['altura']})" for j in lista)


def midia(ctx: Ctx, acao: str, app: str = "Music") -> str:
    comando, alvo = MEDIA_COMMANDS.get(fold(acao)), MEDIA_APPS.get(fold(app))
    if comando is None or alvo is None:
        raise Falha("Use tocar, pausar, alternar, proxima ou anterior, no Music ou no Spotify.")
    saida = _osascript(ctx.runner, f'if application "{alvo}" is running then', f'tell application "{alvo}" to {comando}', 'return "ok"',
                       "end if", 'return "fechado"')
    return f"{alvo} não está aberto." if saida == "fechado" else f"{alvo}: {acao}."


def brilho(ctx: Ctx, valor: str) -> str:
    v = valor.strip().lower()
    if v in BRIGHTNESS_KEYS:
        linhas = [f"tell application \"System Events\" to key code {BRIGHTNESS_KEYS[v]}"] * BRIGHTNESS_STEPS
        _osascript(ctx.runner, *linhas)
        return f"Brilho {v} ({BRIGHTNESS_STEPS} passos)."
    if not v.isdigit() or not 0 <= int(v) <= 100:
        raise Falha("Use mais, menos ou um número de 0 a 100.")
    r = ctx.runner.run(["brightness", f"{int(v) / 100:.2f}"], timeout=OSASCRIPT_S)
    if r.exit != 0:
        raise Falha("Para um brilho exato preciso do utilitário brightness (brew install brightness); sem ele só consigo mais ou menos.")
    return f"Brilho em {int(v)}%."


def modo_escuro(ctx: Ctx, modo: str) -> str:
    valor = DARK_MODES.get(fold(modo))
    if valor is None:
        raise Falha("Use escuro, claro ou alternar.")
    _osascript(ctx.runner, f'tell application "System Events" to tell appearance preferences to set dark mode to {valor}')
    return f"Aparência: {modo}."


def wifi(ctx: Ctx) -> str:
    portas = ctx.runner.run(["networksetup", "-listallhardwareports"], timeout=OSASCRIPT_S)
    dispositivo = re.search(r"Hardware Port: (?:Wi-Fi|AirPort)\s*\nDevice: (\w+)", portas.stdout)
    if portas.exit != 0 or not dispositivo:
        return "Este Mac não tem Wi-Fi."
    nome = dispositivo.group(1)
    energia = ctx.runner.run(["networksetup", "-getairportpower", nome], timeout=OSASCRIPT_S)
    if energia.exit != 0:
        raise Falha("Não consegui ler o Wi-Fi agora.")
    if re.search(r":\s*off\s*$", energia.stdout.strip(), re.I):
        return "O Wi-Fi está desligado."
    rede = ctx.runner.run(["networksetup", "-getairportnetwork", nome], timeout=OSASCRIPT_S)
    achada = re.search(r"Network:\s*(.+)", rede.stdout)
    if achada and "redacted" not in achada.group(1).lower():
        return f"O Wi-Fi está ligado, na rede {achada.group(1).strip()}."
    return "O Wi-Fi está ligado (o macOS não mostra o nome da rede)."


def ajustes(ctx: Ctx, painel: str) -> str:
    chave = fold(painel).replace(" ", "-")
    destino = PANES.get(chave) or (painel.strip() if painel.strip().startswith(SETTINGS_SCHEME) else None)
    if destino is None:
        raise Falha("Painéis: " + ", ".join(sorted(PANES)) + ".")
    url = destino if destino.startswith(SETTINGS_SCHEME) else SETTINGS_SCHEME + destino
    r = ctx.runner.run(["open", url], timeout=OSASCRIPT_S)
    if r.timed_out or r.exit != 0:
        raise Falha("Não consegui abrir Ajustes do Sistema.")
    return f"Abri Ajustes do Sistema em {painel}."


def atalhos(ctx: Ctx) -> str:
    r = ctx.runner.run(["shortcuts", "list"], timeout=OSASCRIPT_S)
    if r.exit != 0:
        raise Falha("Não consegui listar os Atalhos.")
    return r.stdout.strip() or "Nenhum atalho criado."


def app_setting(ctx: Ctx, key: str) -> list[str]:
    if key in ctx.settings_cache:
        return ctx.settings_cache[key]
    values: list[str] = []
    r = ctx.runner.run(["defaults", "export", SETTINGS_DOMAIN, "-"], timeout=OSASCRIPT_S)
    if r.exit == 0:
        try:
            raw = plistlib.loads(r.stdout.encode()).get(key)
        except (ValueError, plistlib.InvalidFileException):
            raw = None
        values = [v for v in raw if isinstance(v, str)] if isinstance(raw, list) else []
    ctx.settings_cache[key] = values
    return values


def shortcut_allowlist(ctx: Ctx) -> set[str]:
    return set(app_setting(ctx, SHORTCUTS_KEY))


def safe_app(ctx: Ctx, app: str | None) -> bool:
    name = fold(app or "")
    if not name or is_browser(app) or is_messenger(app):
        return False
    allowed = {fold(n) for n in (*DEFAULT_SAFE_APPS, *app_setting(ctx, SAFE_APPS_KEY))}
    return name in allowed


def needs_card(ctx: Ctx, info: dict) -> bool:
    return not safe_app(ctx, str(info.get("app") or ""))


def run_shortcut(ctx: Ctx, nome: str, entrada: str | None = None) -> str:
    argv = ["shortcuts", "run", nome]
    arquivo: Path | None = None
    if entrada is not None:
        ctx.paths.state.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix="atalho-", suffix=".txt", dir=ctx.paths.state)
        arquivo = Path(name)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(entrada)
        argv += ["--input-path", name]
    try:
        r = ctx.runner.run(argv, timeout=120)
    finally:
        if arquivo is not None:
            arquivo.unlink(missing_ok=True)
    if r.timed_out:
        raise Falha("O atalho demorou demais e foi cancelado.")
    if r.exit != 0:
        raise Falha(f"O atalho {nome} não rodou: {(r.stderr.strip() or 'não achei esse atalho')[:200]}")
    return r.stdout.strip() or f"Rodei o atalho {nome}."


def atalho(ctx: Ctx, nome: str, entrada: str | None = None) -> str:
    if not nome.strip():
        raise Falha("Informe o nome do atalho.")
    if SHORTCUT_SENDS.search(nome) or nome not in shortcut_allowlist(ctx):
        raise Falha(ATALHO_ENVIA)
    return run_shortcut(ctx, nome, entrada)


def shell_bodies(script: str) -> list[str]:
    return [(a or b).replace('\\"', '"').replace("\\\\", "\\") for a, b in SHELL_IN_SCRIPT.findall(script)]


def script_refusal(ctx: Ctx, script: str) -> str | None:
    paths, cfg = ctx.paths, ctx.settings()
    commands = ["osascript -e " + shlex.quote(script), *shell_bodies(script)]
    for command in commands:
        payload = {"tool_name": "Bash", "tool_input": {"command": command}, "cwd": str(paths.home)}
        if scan_text(command) or SECRET_COMMAND.search(command) or hook_guard_secrets(payload, paths):
            return SEGREDO
    for command in commands:
        payload = {"tool_name": "Bash", "tool_input": {"command": command}, "cwd": str(paths.home)}
        reason = hook_guard_destructive(payload, paths, cfg) or hook_guard_outbound(payload, paths, ui_scripts=False)
        if reason:
            return "Recusei: " + reason.removeprefix("wisp-guard:").strip()
    return None


def run_script(ctx: Ctx, codigo: str, linguagem: str) -> str:
    argv = ["osascript", *(["-l", "JavaScript"] if linguagem != "applescript" else []), "-e", codigo]
    r = ctx.runner.run(argv, timeout=OSASCRIPT_S)
    if r.timed_out:
        raise Falha("O script demorou demais e foi cancelado.")
    if r.exit != 0:
        raise Falha(SEM_AUTOMACAO if NEGADO.search(r.stderr) else f"O script falhou: {r.stderr.strip()[:300]}")
    return r.stdout.strip() or "Script executado."


def script(ctx: Ctx, codigo: str, linguagem: str = "applescript") -> str:
    if not codigo.strip():
        raise Falha("Informe o script.")
    lang = fold(linguagem)
    if lang not in ("applescript", "jxa", "javascript"):
        raise Falha("A linguagem é applescript ou jxa.")
    label = "AppleScript" if lang == "applescript" else "JXA"
    return enviar(ctx, label, ["script"], "script", codigo, acao="script")


def arvore(ctx: Ctx, app: str | None = None, maximo: int = 400, profundidade: int = 8, completo: bool = False) -> str:
    args = ["arvore", "--max", str(max(1, min(maximo, TREE_MAX))), "--profundidade", str(max(1, min(profundidade, 20)))]
    return ctx.helper_run(*args, *(["--completo"] if completo else []), *(["--app", app] if app else []))


def clicar(ctx: Ctx, titulo: str | None = None, papel: str | None = None, ponto: str | None = None, indice: int = 0,
           app: str | None = None, regex: str | None = None) -> str:
    if not (titulo or papel or ponto or regex):
        raise Falha("Informe o título, o papel ou o ponto do que clicar.")
    if ponto:
        seen = ctx.helper_json("clicar", "--ponto", ponto, "--resolver")
        owner = str(seen.get("app") or "")
        info = {**focus_info(ctx, owner or None), "app": owner} if owner else focus_info(ctx, app)
        args = ["clicar", "--ponto", ponto]
    else:
        info = focus_info(ctx, app)
        args = ["clicar", *(["--titulo", titulo] if titulo else []), *(["--regex", regex] if regex else []),
                *(["--papel", papel] if papel else []), "--indice", str(max(0, indice)), *(["--app", app] if app else [])]
    if needs_card(ctx, info):
        args += ["--bloquear", SEND_PATTERN]
    try:
        feito = ctx.helper_json(*args)
    except Falha as e:
        raise Falha(ENVIO_DIRETO if "mac_send" in str(e) else str(e)) from None
    nome = feito.get("titulo") or feito.get("descricao") or feito.get("papel") or "o ponto pedido"
    return f"Cliquei em {nome}."


def writable_focus(ctx: Ctx, app: str | None) -> dict:
    info = focus_info(ctx, app)
    if info.get("seguro"):
        raise Falha(SENHA)
    if not info.get("papel"):
        raise Falha(FOCO_ILEGIVEL)
    return info


def digitar(ctx: Ctx, texto: str, app: str | None = None) -> str:
    if not texto:
        raise Falha("Informe o texto.")
    info = writable_focus(ctx, app)
    if needs_card(ctx, info) and ("\n" in texto or "\r" in texto):
        raise Falha(ENVIO_DIRETO)
    ctx.helper_run("digitar", texto, *(["--app", app] if app else []))
    return f"Digitei {len(texto)} caracteres."


def tecla(ctx: Ctx, combo: str, app: str | None = None) -> str:
    combo = parse_combo(combo)
    info = writable_focus(ctx, app)
    if needs_card(ctx, info) and key_sends(combo):
        raise Falha(ENVIO_DIRETO)
    ctx.helper_run("tecla", combo, *(["--app", app] if app else []))
    return f"Apertei {combo}."


def rolar(ctx: Ctx, direcao: str = "baixo", quantidade: int = 5, app: str | None = None) -> str:
    if fold(direcao) not in ("cima", "baixo", "esquerda", "direita"):
        raise Falha("A direção é cima, baixo, esquerda ou direita.")
    ctx.helper_run("rolar", "--direcao", fold(direcao), "--quantidade", str(max(1, min(quantidade, 50))), *(["--app", app] if app else []))
    return f"Rolei para {fold(direcao)}."


def menu(ctx: Ctx, caminho: str, app: str | None = None) -> str:
    ultimo = caminho.split(">")[-1]
    if needs_card(ctx, focus_info(ctx, app)) and send_title(ultimo):
        raise Falha(ENVIO_DIRETO)
    ctx.helper_run("menu", caminho, *(["--app", app] if app else []))
    return f"Escolhi o menu {caminho}."


def tela(ctx: Ctx, app: str | None = None) -> str:
    if not app:
        return print_tela(ctx.runner, ctx.paths, False)
    lista = [j for j in ctx.helper_json("janelas", "--app", app) if j.get("largura", 0) > 0]
    if not lista:
        raise Falha(f"Não achei uma janela de {app} na tela.")
    return print_tela(ctx.runner, ctx.paths, False, janela_id=int(lista[0]["id"]))


def is_email_app(app: str) -> bool:
    return any(part in fold(app) for part in ("mail", "outlook", "thunderbird", "spark")) or is_browser(app)


def composicao(ctx: Ctx, app: str) -> dict:
    data = ctx.helper_json("composicao", "--app", app)
    if not isinstance(data, dict):
        raise Falha(FOCO_ILEGIVEL)
    janela = canon(str(data.get("janela") or ""))
    destinatarios = [canon(str(d)) for d in data.get("destinatarios") or [] if str(d).strip()]
    if not destinatarios and janela and not is_email_app(app):
        destinatarios = [janela]
    return {"app": str(data.get("app") or ""), "corpo": canon(str(data.get("corpo") or "")), "destinatarios": destinatarios,
            "assunto": canon(str(data.get("assunto") or ""))}


def snapshot(info: dict) -> tuple:
    return (info["corpo"], tuple(sorted(info["destinatarios"])), info["assunto"])


def confirm_compose(ctx: Ctx, app: str, para: list[str], assunto: str, corpo: str) -> dict:
    if not (is_messenger(app) or is_browser(app)) or not sensitive(focus_info(ctx, app)):
        raise Falha(NAO_MENSAGEIRO)
    atual = composicao(ctx, app)
    if not atual["corpo"]:
        raise Falha("Não achei texto escrito no campo da mensagem; escreva a mensagem no app e tente de novo.")
    if not atual["destinatarios"]:
        raise Falha("Não consegui ler para quem a mensagem vai; não enviei.")
    if corpo != atual["corpo"]:
        raise Falha("O texto que você me passou não é igual ao que está escrito no campo da mensagem; não enviei. "
                    "Texto da janela: " + json.dumps(atual["corpo"][:200], ensure_ascii=False))
    if sorted(para) != sorted(atual["destinatarios"]) or len(set(para)) != len(para):
        raise Falha("Os destinatários não são iguais aos da janela; não enviei. Na janela: " + json.dumps(atual["destinatarios"], ensure_ascii=False))
    if assunto != atual["assunto"]:
        raise Falha("O assunto não é igual ao da janela; não enviei. Na janela: " + json.dumps(atual["assunto"], ensure_ascii=False))
    return atual


def ask_gate(ctx: Ctx, request: dict) -> None:
    if ctx.gate is None:
        raise Falha("Não enviei: o envio precisa da aprovação do usuário e o canal de aprovação do Wisp não está disponível aqui.")
    try:
        ctx.gate(request)
    except Refused as e:
        raise Falha(str(e)) from None


def enviar(ctx: Ctx, app: str, para: list[str], assunto: str, corpo: str, cc: list[str] | None = None, acao: str | None = None) -> str:
    modo = acao or ("atalho" if fold(app) in ATALHOS_APP else "enviar")
    if modo not in (*ACOES, "enviar"):
        raise Falha("A ação é tecla, texto, clique, script, atalho, ou nenhuma para enviar a mensagem da janela.")
    if modo != "enviar" and assunto != modo:
        raise Falha(ACAO_SUBJECT.format(acao=modo))
    if not corpo.strip() or not para:
        raise Falha("Informe para quem vai e o texto da mensagem.")
    strict = modo not in ("script", "texto")
    if any(p != canon(p) for p in para) or (strict and corpo != canon(corpo)) or assunto != canon(assunto):
        raise Falha("Os textos precisam vir sem espaços sobrando nas pontas e com quebras de linha simples; copie exatamente o que está na janela.")
    request = {"app": app, "to": para, "cc": cc or [], "subject": assunto, "body": corpo}
    if modo == "enviar":
        atual = confirm_compose(ctx, app, para, assunto, corpo)
        ask_gate(ctx, request)
        if snapshot(composicao(ctx, app)) != snapshot(atual):
            raise Falha(JANELA_MUDOU)
        ctx.helper_run("clicar", "--app", app, "--regex", SEND_PATTERN, "--papel", "AXButton")
        return "enviado"
    if modo == "script":
        lang = "jxa" if fold(app) == "jxa" else "applescript"
        if fold(app) not in ("applescript", "jxa"):
            raise Falha("Para scripts o app é AppleScript ou JXA.")
        motivo = script_refusal(ctx, corpo)
        if motivo:
            raise Falha(motivo)
        ask_gate(ctx, {**request, "exibir": escape_controls(corpo)})
        return run_script(ctx, corpo, lang)
    if modo == "atalho":
        ask_gate(ctx, request)
        nome = para[0]
        run_shortcut(ctx, nome, None if corpo == nome else corpo)
        return "enviado"
    ask_gate(ctx, request)
    if fold(focus_info(ctx, app).get("app", "")) != fold(app):
        raise Falha(JANELA_MUDOU)
    if modo == "tecla":
        writable_focus(ctx, app)
        ctx.helper_run("tecla", parse_combo(corpo), "--app", app)
    elif modo == "texto":
        writable_focus(ctx, app)
        ctx.helper_run("digitar", corpo, "--app", app)
    else:
        ctx.helper_json("clicar", "--titulo", corpo, "--indice", "0", "--app", app)
    return "feito"


REDACTED = {"mac_send": ("body", "subject", "to", "cc", "exibir"), "mac_shortcut": ("entrada",), "mac_ui_type": ("texto",), "mac_script": ("script",)}
LENGTH_ONLY_RESULT = frozenset({"mac_ui_tree", "mac_script", "mac_screenshot", "mac_shortcut", "mac_send"})


def redact(tool: str, args: dict) -> dict:
    hidden = REDACTED.get(tool, ())
    return {k: (f"<{len(v) if isinstance(v, str) else len(json.dumps(v, ensure_ascii=False))} caracteres>" if k in hidden else (v if len(str(v)) <= LOG_FIELD else str(v)[:LOG_FIELD] + "…"))
            for k, v in args.items()}


def registrar(ctx: Ctx, tool: str, args: dict, fase: str, resultado: str = "") -> None:
    pasta = ctx.paths.state
    arquivo = pasta / LOG_NAME
    linha = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "ferramenta": tool, "fase": fase, "args": redact(tool, args)}
    if resultado and tool in LENGTH_ONLY_RESULT:
        linha["resultado"] = f"<{len(resultado)} caracteres>"
    elif resultado:
        linha["resultado"] = resultado[:LOG_FIELD]
    try:
        pasta.mkdir(parents=True, exist_ok=True)
        os.chmod(pasta, 0o700)
        if arquivo.exists() and arquivo.stat().st_size > LOG_LIMIT:
            arquivo.replace(arquivo.with_suffix(".jsonl.1"))
        fd = os.open(arquivo, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as f:
            f.write(json.dumps(linha, ensure_ascii=False) + "\n")
    except OSError:
        if fase == "pedido":
            raise Falha("Não consegui registrar a ação no histórico; por segurança não executei.") from None


@dataclass(frozen=True)
class Tool:
    name: str
    description: str
    properties: dict
    required: tuple[str, ...]
    read_only: bool
    run: Callable[[Ctx, dict], str]

    @property
    def schema(self) -> dict:
        return {"type": "object", "properties": self.properties, "required": list(self.required)}


def _s(description: str) -> dict:
    return {"type": "string", "description": description}


def _i(description: str) -> dict:
    return {"type": "integer", "description": description}


def _list(description: str) -> dict:
    return {"type": "array", "items": {"type": "string"}, "description": description}


APP = _s("nome do app (padrão: o app da frente)")


def _g(args: dict, key: str, default=None):
    value = args.get(key)
    return default if value is None else value


TOOLS: dict[str, Tool] = {t.name: t for t in [
    Tool("mac_apps", "Lista os apps abertos no Mac e qual está na frente", {}, (), True, lambda c, a: apps(c)),
    Tool("mac_windows", "Lista as janelas abertas (app, título, tamanho)", {"app": _s("filtrar por app")}, (), True,
         lambda c, a: janelas(c, a.get("app"))),
    Tool("mac_ui_tree", "Lê a árvore de interface da janela da frente: papel, título, valor e posição de cada elemento, com um número [n]. "
         "Use antes de clicar para ver o que existe.",
         {"app": APP, "max": _i("máximo de elementos (400)"), "profundidade": _i("níveis (8)")}, (), True,
         lambda c, a: arvore(c, a.get("app"), int(_g(a, "max", 400)), int(_g(a, "profundidade", 8)))),
    Tool("mac_battery", "Mostra a bateria do Mac", {}, (), True, lambda c, a: bateria(c.runner)),
    Tool("mac_wifi", "Mostra se o Wi-Fi está ligado e a rede", {}, (), True, lambda c, a: wifi(c)),
    Tool("mac_dnd_status", "Mostra se o Não perturbe está ligado", {}, (), True, lambda c, a: nao_perturbe(c.paths)),
    Tool("mac_screenshot", "Tira um print da tela inteira ou da janela de um app e devolve o caminho do arquivo",
         {"app": _s("app cuja janela capturar (padrão: a tela inteira)")}, (), True, lambda c, a: tela(c, a.get("app"))),
    Tool("mac_shortcuts_list", "Lista os Atalhos (Shortcuts) do Mac", {}, (), True, lambda c, a: atalhos(c)),
    Tool("mac_open", "Abre um app, arquivo ou endereço (https, mailto). Para um site use mac_open_url. Para abrir um arquivo num app específico (Preview…) passe com",
         {"alvo": _s("nome do app, caminho do arquivo ou URL"), "com": _s("app que abre o arquivo, como Preview")}, ("alvo",), False,
         lambda c, a: abrir(c.runner, a["alvo"], a.get("com"))),
    Tool("mac_open_url", "Abre um site no navegador. 'abre o YouTube': site=youtube. 'toca X no YouTube': site=youtube, busca=X. "
         "'pesquisa X no Google': site=google, busca=X. Ou passe a url completa.",
         {"url": _s("endereço http/https completo"), "site": _s("youtube, google, maps, wikipedia, github, gmail, whatsapp, spotify, netflix, amazon ou um domínio"),
          "busca": _s("o que buscar no site"), "navegador": _s("safari, chrome, firefox, arc, brave, edge (padrão: o navegador padrão)")},
         (), False, lambda c, a: abrir_url(c, a.get("url"), a.get("site"), a.get("busca"), a.get("navegador"))),
    Tool("mac_app", "Traz um app para a frente, esconde ou fecha",
         {"acao": _s("focar, esconder ou sair"), "app": _s("nome do app")}, ("acao", "app"), False,
         lambda c, a: app_acao(c, a["acao"], a["app"])),
    Tool("mac_volume", "Define o volume (0-100) ou deixa no mudo", {"valor": _s("0 a 100, ou mudo")}, ("valor",), False,
         lambda c, a: volume(c.runner, str(a["valor"]))),
    Tool("mac_media", "Controla a música do Music ou do Spotify",
         {"acao": _s("tocar, pausar, alternar, proxima ou anterior"), "app": _s("Music ou Spotify (padrão Music)")}, ("acao",), False,
         lambda c, a: midia(c, a["acao"], _g(a, "app", "Music"))),
    Tool("mac_brightness", "Muda o brilho da tela", {"valor": _s("mais, menos ou 0 a 100 (número exato precisa do utilitário brightness)")},
         ("valor",), False, lambda c, a: brilho(c, str(a["valor"]))),
    Tool("mac_dark_mode", "Troca a aparência do Mac", {"modo": _s("escuro, claro ou alternar")}, ("modo",), False,
         lambda c, a: modo_escuro(c, a["modo"])),
    Tool("mac_settings_pane", "Abre um painel dos Ajustes do Sistema", {"painel": _s("acessibilidade, wifi, som, bateria, monitores, notificacoes, teclado, bluetooth, rede, privacidade…")},
         ("painel",), False, lambda c, a: ajustes(c, a["painel"])),
    Tool("mac_notify", "Mostra uma notificação do Mac", {"texto": _s("texto")}, ("texto",), False, lambda c, a: notificar(c.runner, a["texto"])),
    Tool("mac_shortcut", "Roda um Atalho (Shortcuts) de leitura pelo nome, com um texto de entrada opcional. Qualquer outro atalho exige mac_send com app=Atalhos",
         {"nome": _s("nome do atalho"), "entrada": _s("texto de entrada")}, ("nome",), False, lambda c, a: atalho(c, a["nome"], a.get("entrada"))),
    Tool("mac_script", "Roda AppleScript ou JXA para automatizar apps. Pede sempre a aprovação do usuário e mostra o script inteiro; mexer em senhas ou chaveiro é recusado. Sob o Claude use mac_send com acao=script (app=AppleScript ou JXA)",
         {"script": _s("o código"), "linguagem": _s("applescript (padrão) ou jxa")}, ("script",), False,
         lambda c, a: script(c, a["script"], _g(a, "linguagem", "applescript"))),
    Tool("mac_ui_click", "Clica num elemento da janela pelo título e/ou papel (AXButton…), ou num ponto x,y. Rótulos de enviar/confirmar são recusados fora dos apps seguros: use mac_send acao=clique",
         {"titulo": _s("título ou descrição do elemento"), "papel": _s("papel AX, como AXButton"), "ponto": _s("x,y na tela"),
          "indice": _i("qual dos achados (0 é o primeiro)"), "app": APP}, (), False,
         lambda c, a: clicar(c, a.get("titulo"), a.get("papel"), a.get("ponto"), int(_g(a, "indice", 0)), a.get("app"))),
    Tool("mac_ui_type", "Digita texto no campo em foco. Recusa campo de senha", {"texto": _s("texto"), "app": APP}, ("texto",), False,
         lambda c, a: digitar(c, a["texto"], a.get("app"))),
    Tool("mac_ui_key", "Aperta uma tecla ou atalho, como cmd+t, return, cmd+shift+4", {"tecla": _s("combinação"), "app": APP}, ("tecla",), False,
         lambda c, a: tecla(c, a["tecla"], a.get("app"))),
    Tool("mac_ui_scroll", "Rola a janela", {"direcao": _s("cima, baixo, esquerda ou direita"), "quantidade": _i("linhas (5)"), "app": APP},
         ("direcao",), False, lambda c, a: rolar(c, a["direcao"], int(_g(a, "quantidade", 5)), a.get("app"))),
    Tool("mac_ui_menu", "Escolhe um item da barra de menus por caminho", {"caminho": _s("como 'Arquivo > Exportar como PDF'"), "app": APP},
         ("caminho",), False, lambda c, a: menu(c, a["caminho"], a.get("app"))),
    Tool("mac_send", "Tudo o que envia, confirma ou executa algo e precisa da aprovação do usuário. Sem acao: envia a mensagem escrita na janela de um app de "
         "mensagem ou webmail (Mail, Mensagens, WhatsApp, Gmail…); body, to e subject precisam ser iguais ao campo da mensagem, à linha Para e ao Assunto da janela. "
         "acao=tecla (to=[tecla], subject=tecla, body=tecla), texto (to=[app], subject=texto, body=texto), clique (to=[rótulo], subject=clique, body=rótulo) "
         "em app não seguro; acao=script (app=AppleScript ou JXA, to=[script], subject=script, body=o script); acao=atalho (app=Atalhos, to=[nome], subject=atalho, "
         "body=texto de entrada ou o nome). Sem aprovação nada acontece.",
         {"app": _s("app alvo, AppleScript/JXA ou Atalhos"), "to": _list("destinatários como na janela, ou o alvo da ação"), "subject": _s("assunto da janela (vazio se não houver) ou o nome da ação"),
          "body": _s("o texto exato da mensagem ou o conteúdo da ação"), "cc": _list("cópias"), "acao": _s("tecla, texto, clique, script ou atalho; vazio para enviar a mensagem da janela")},
         ("app", "to", "subject", "body"), False,
         lambda c, a: enviar(c, a["app"], list(a["to"]), a["subject"], a["body"], a.get("cc"), a.get("acao"))),
]}
READ_ONLY = frozenset(name for name, tool in TOOLS.items() if tool.read_only)
ALWAYS_ASK = frozenset({"mac_send", "mac_script"})


def call(ctx: Ctx, name: str, args: dict) -> str:
    tool = TOOLS.get(name)
    if tool is None:
        raise Falha(f"a ferramenta {name} não existe")
    missing = [key for key in tool.required if args.get(key) is None]
    if missing:
        raise Falha(f"faltou informar: {', '.join(missing)}")
    registrar(ctx, name, args, "pedido")
    try:
        saida = tool.run(ctx, args)
    except Falha as e:
        registrar(ctx, name, args, "recusado" if str(e).startswith("Recusei") else "falhou", str(e))
        raise
    registrar(ctx, name, args, "feito", saida)
    return saida


def add_commands(cmds) -> None:
    def add(name: str, *flags: str, positional: tuple[str, ...] = ()):
        p = cmds.add_parser(name)
        for arg in positional:
            p.add_argument(arg)
        for flag in flags:
            p.add_argument(flag)
        return p

    p = add("abrir-url", "--url", "--site", "--busca", "--navegador")
    p.set_defaults(tool="mac_open_url")
    add("app", positional=("acao", "app")).set_defaults(tool="mac_app")
    cmds.add_parser("apps").set_defaults(tool="mac_apps")
    add("janelas", "--app").set_defaults(tool="mac_windows")
    p = add("midia", "--app", positional=("acao",))
    p.set_defaults(tool="mac_media")
    add("brilho", positional=("valor",)).set_defaults(tool="mac_brightness")
    add("modo-escuro", positional=("modo",)).set_defaults(tool="mac_dark_mode")
    cmds.add_parser("wifi").set_defaults(tool="mac_wifi")
    add("ajustes", positional=("painel",)).set_defaults(tool="mac_settings_pane")
    cmds.add_parser("atalhos").set_defaults(tool="mac_shortcuts_list")
    add("atalho", "--entrada", positional=("nome",)).set_defaults(tool="mac_shortcut")
    p = add("script", "--linguagem", positional=("script",))
    p.set_defaults(tool="mac_script")
    p = add("arvore", "--app", "--max", "--profundidade")
    p.set_defaults(tool="mac_ui_tree")
    p = add("clicar", "--titulo", "--papel", "--ponto", "--indice", "--app")
    p.set_defaults(tool="mac_ui_click")
    add("digitar", "--app", positional=("texto",)).set_defaults(tool="mac_ui_type")
    add("tecla", "--app", positional=("tecla",)).set_defaults(tool="mac_ui_key")
    add("rolar", "--quantidade", "--app", positional=("direcao",)).set_defaults(tool="mac_ui_scroll")
    add("menu", "--app", positional=("caminho",)).set_defaults(tool="mac_ui_menu")


INT_ARGS = frozenset({"max", "profundidade", "indice", "quantidade"})


def cli_args(namespace) -> dict:
    keys = set(TOOLS[namespace.tool].properties)
    out = {}
    for key in keys:
        value = getattr(namespace, key, None)
        if value is not None:
            out[key] = int(value) if key in INT_ARGS else value
    return out
