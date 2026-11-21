from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

from wisp.paths import WispPaths
from wisp.runner import Runner, RunResult, SubprocessRunner

OSASCRIPT_S = 30
CAPTURA_S = 15
CAPTURA_JANELA_S = 60
URL = re.compile(r"^(https?|mailto):", re.I)
BATERIA = re.compile(r"(\d+)%;\s*([^;]+);(?:\s*(\d+):(\d{2}) remaining)?")
ESTADOS_BATERIA = {"discharging": "descarregando", "charging": "carregando", "charged": "carregada",
                   "finishing charge": "terminando de carregar", "AC attached": "na tomada"}
SEM_AUTOMACAO = ("Não tenho permissão para controlar o Mac. Abra Ajustes do Sistema > Privacidade e Segurança > Automação "
                 "e ative o Wisp.")
SEM_TELA = ("Não consegui capturar a tela. Abra Ajustes do Sistema > Privacidade e Segurança > Gravação de Tela "
            "e ative o Wisp.")
NEGADO = re.compile(r"not authorized|not allowed|(-1743)|(-1744)|assistive", re.I)
CAPTURA_VALIDADE_S = 86400
PASTAS_APPS = ("/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities")
REVELAR = {
    "app", "terminal", "command", "tool", "workflow", "action", "pkg", "mpkg", "dmg", "iso", "jar", "webloc", "inetloc",
    "fileloc", "url", "scpt", "scptd", "osa", "saver", "prefpane", "plugin", "bundle", "kext", "appex", "xpc",
    "sh", "bash", "zsh", "csh", "ksh", "fish", "py", "rb", "pl", "js", "mjs", "lua", "php", "exe", "bat", "cmd", "msi",
    "ps1", "vbs", "docm", "xlsm", "pptm", "dotm", "xltm", "potm", "xlam", "ppam", "wsf", "lnk", "desktop", "scr",
    "mobileconfig", "jnlp", "ics", "webarchive", "html", "htm", "xhtml", "svg", "svgz",
}
ABRIR = {
    "txt", "md", "csv", "tsv", "json", "log", "yaml", "yml", "rtf", "pdf", "doc", "docx", "odt", "pages", "xls", "xlsx",
    "ods", "numbers", "ppt", "pptx", "odp", "key", "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp",
    "mp4", "mov", "m4v", "mkv", "avi", "webm", "mp3", "m4a", "wav", "aac", "flac", "aiff",
}
DND_ASSERTIONS = "Library/DoNotDisturb/DB/Assertions.json"


class Falha(Exception):
    pass


def _osascript(runner: Runner, *linhas: str, args: tuple[str, ...] = ()) -> str:
    argv = ["osascript"]
    for linha in linhas:
        argv += ["-e", linha]
    r = runner.run([*argv, *(["--", *args] if args else [])], timeout=OSASCRIPT_S)
    if r.timed_out:
        raise Falha("O Mac demorou demais para responder. Tente de novo.")
    if r.exit != 0:
        raise Falha(SEM_AUTOMACAO if NEGADO.search(r.stderr) else "O Mac não conseguiu fazer isso agora.")
    return r.stdout.strip()


def so_mostrar(p: Path) -> bool:
    ext = p.suffix.lower().lstrip(".")
    if p.is_dir() or not ext or ext in REVELAR or ext not in ABRIR:
        return True
    return os.access(p, os.X_OK)


def _app_instalado(nome: str) -> Path | None:
    alvo = (nome[:-4] if nome.lower().endswith(".app") else nome).casefold()
    for pasta in (*PASTAS_APPS, str(Path.home() / "Applications")):
        try:
            for p in sorted(Path(pasta).glob("*.app")):
                if p.stem.casefold() == alvo:
                    return p
        except OSError:
            continue
    return None


def abrir(runner: Runner, alvo: str, com: str | None = None) -> str:
    caminho = Path(os.path.expanduser(alvo))
    mostrar = False
    if URL.match(alvo):
        argv = ["open", alvo]
    elif caminho.exists():
        mostrar = so_mostrar(caminho)
        leitor = _app_instalado(com) if com else None
        if com and leitor is None:
            raise Falha(f"Não achei o aplicativo {com} para abrir {alvo}.")
        if mostrar:
            argv = ["open", "-R", str(caminho)]
        else:
            argv = ["open", *(["-a", str(leitor)] if leitor else []), str(caminho)]
    elif (app := _app_instalado(alvo)) is not None:
        argv = ["open", "-a", str(app)]
    else:
        raise Falha(f"Não consegui abrir {alvo}: não achei esse aplicativo, arquivo ou endereço.")
    r = runner.run(argv, timeout=OSASCRIPT_S)
    if r.timed_out or r.exit != 0:
        raise Falha(f"Não consegui abrir {alvo}.")
    if mostrar:
        return f"Só mostrei {alvo} no Finder, sem abrir: esse tipo de arquivo pode executar algo, então quem decide é você."
    return f"Abri {alvo}."


def volume(runner: Runner, valor: str) -> str:
    v = valor.strip().lower()
    if v in ("mudo", "mute"):
        _osascript(runner, "set volume output muted true")
        return "Deixei o som do Mac no mudo."
    if not v.isdigit() or not 0 <= int(v) <= 100:
        raise Falha("Use um número de 0 a 100, ou a palavra mudo.")
    _osascript(runner, f"set volume output volume {int(v)}", "set volume output muted false")
    return f"Volume do Mac em {int(v)}."


def notificar(runner: Runner, texto: str) -> str:
    _osascript(runner, "on run argv", 'display notification (item 1 of argv) with title "Wisp"', "end run", args=(texto,))
    return "Mostrei a notificação."


def print_tela(runner: Runner, paths: WispPaths, janela: bool, agora: datetime | None = None, janela_id: int | None = None) -> str:
    pasta = paths.state / "capturas"
    pasta.mkdir(parents=True, exist_ok=True)
    _limpar_capturas(pasta)
    alvo = pasta / f"captura-{(agora or datetime.now()).strftime('%Y%m%d-%H%M%S')}.png"
    argv = ["screencapture", "-x", "-o", *(["-w"] if janela else []), *(["-l", str(janela_id)] if janela_id is not None else []), str(alvo)]
    r: RunResult = runner.run(argv, timeout=CAPTURA_JANELA_S if janela else CAPTURA_S)
    if r.timed_out:
        raise Falha("A captura demorou demais e foi cancelada.")
    if r.exit != 0 or not alvo.is_file() or alvo.stat().st_size == 0:
        if janela and r.exit == 0 and not alvo.exists():
            raise Falha("A captura da janela foi cancelada.")
        raise Falha(SEM_TELA)
    return str(alvo)


def _limpar_capturas(pasta: Path) -> None:
    corte = time.time() - CAPTURA_VALIDADE_S
    for p in pasta.glob("captura-*.png"):
        try:
            if p.stat().st_mtime < corte:
                p.unlink()
        except OSError:
            continue


def bateria(runner: Runner) -> str:
    r = runner.run(["pmset", "-g", "batt"], timeout=OSASCRIPT_S)
    if r.exit != 0:
        raise Falha("Não consegui ler a bateria agora.")
    m = BATERIA.search(r.stdout)
    if not m:
        return "Este Mac não tem bateria (está na tomada)."
    pct, estado = m.group(1), m.group(2).strip()
    texto = f"Bateria em {pct}%, {ESTADOS_BATERIA.get(estado, estado)}"
    restante = (int(m.group(3)), m.group(4)) if m.group(3) is not None and (int(m.group(3)), int(m.group(4))) != (0, 0) else None
    if restante and estado == "discharging":
        texto += f", restam {restante[0]}h{restante[1]}"
    elif restante and estado in ("charging", "finishing charge"):
        texto += f", cheia em {restante[0]}h{restante[1]}"
    return texto + "."


def nao_perturbe(paths: WispPaths) -> str:
    arquivo = paths.home / DND_ASSERTIONS
    try:
        dados = json.loads(arquivo.read_text("utf-8"))
    except PermissionError:
        return ("Não consigo ver se o Não perturbe está ligado: o macOS só deixa com Acesso Total ao Disco. "
                "Não mexo nele; ligue ou desligue pela Central de Controle.")
    except (OSError, ValueError):
        return "Não consegui ver se o Não perturbe está ligado. Não mexo nele; use a Central de Controle."
    ligado = any(item.get("storeAssertionRecords") for item in dados.get("data", []) if isinstance(item, dict))
    return "O Não perturbe está ligado." if ligado else "O Não perturbe está desligado."


def _control(a: argparse.Namespace) -> str:
    from wisp.mac_control import Ctx, call, cli_args

    return call(Ctx(SubprocessRunner(), WispPaths.current()), a.tool, cli_args(a))


def _cmd(a: argparse.Namespace) -> str:
    runner = SubprocessRunner()
    if getattr(a, "tool", None):
        return _control(a)
    if a.mac_cmd == "abrir":
        return abrir(runner, a.alvo, a.com)
    if a.mac_cmd == "volume":
        return volume(runner, a.valor)
    if a.mac_cmd == "notificar":
        return notificar(runner, a.texto)
    if a.mac_cmd == "print" and a.app:
        from wisp.mac_control import Ctx, tela

        return tela(Ctx(runner, WispPaths.current()), a.app)
    if a.mac_cmd == "print":
        return print_tela(runner, WispPaths.current(), a.janela)
    if a.mac_cmd == "bateria":
        return bateria(runner)
    return nao_perturbe(WispPaths.current())


def add_parser(sub) -> argparse.ArgumentParser:
    mac = sub.add_parser("mac", help="everyday Mac actions")
    cmds = mac.add_subparsers(dest="mac_cmd", required=True)
    abrir_cmd = cmds.add_parser("abrir")
    abrir_cmd.add_argument("alvo")
    abrir_cmd.add_argument("--com")
    cmds.add_parser("volume").add_argument("valor")
    cmds.add_parser("notificar").add_argument("texto")
    print_cmd = cmds.add_parser("print")
    print_cmd.add_argument("--janela", action="store_true")
    print_cmd.add_argument("--app")
    cmds.add_parser("bateria")
    cmds.add_parser("nao-perturbe")
    from wisp.mac_control import add_commands

    add_commands(cmds)
    return mac


def run(a: argparse.Namespace) -> int:
    try:
        print(_cmd(a))
        return 0
    except Falha as e:
        print(str(e), file=sys.stderr)
        return 1
