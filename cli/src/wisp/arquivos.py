from __future__ import annotations

import argparse
import ctypes
import json
import os
import re
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from wisp.fsops import atomic_write
from wisp.paths import WispPaths
from wisp.runner import Runner, SubprocessRunner

MAX_RESULTADOS = 30
MAX_CANDIDATOS = 20000
MAX_VARRIDOS = 50000
MAX_PROFUNDIDADE = 6
MDFIND_S = 20
INSTALADOR_DIAS = 30
TRASH = "/usr/bin/trash"
DURACAO = re.compile(r"^(\d+)([hdwm])$")
SEGUNDOS = {"h": 3600, "d": 86400, "w": 7 * 86400, "m": 30 * 86400}
MOSTRAR_POR_GRUPO = 6

TIPOS = {
    "pdf": {"pdf"},
    "imagem": {"jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp", "svg"},
    "documento": {"doc", "docx", "odt", "rtf", "txt", "md", "pages"},
    "planilha": {"xls", "xlsx", "csv", "numbers", "ods"},
    "apresentacao": {"ppt", "pptx", "key", "odp"},
    "video": {"mp4", "mov", "mkv", "avi", "m4v", "webm"},
    "audio": {"mp3", "m4a", "wav", "aac", "flac", "aiff"},
    "compactado": {"zip", "rar", "7z", "tar", "gz", "tgz"},
    "instalador": {"dmg", "pkg"},
}
GRUPOS = {
    "Documentos": TIPOS["pdf"] | TIPOS["documento"] | TIPOS["planilha"] | TIPOS["apresentacao"],
    "Imagens": TIPOS["imagem"],
    "Vídeos": TIPOS["video"],
    "Áudios": TIPOS["audio"],
    "Instaladores": TIPOS["instalador"],
    "Compactados": TIPOS["compactado"],
}
OUTROS = "Outros"
RENAME_EXCL = 0x4
TENTATIVAS_NOME = 5
MARCAS_DE_PROJETO = {".git", "package.json", "pyproject.toml", "Makefile", "Cargo.toml", "go.mod", "pom.xml", "build.gradle",
                     "Package.swift", "Gemfile", "requirements.txt", "composer.json", "CMakeLists.txt", "setup.py"}
SUFIXOS_DE_PROJETO = (".xcodeproj", ".xcworkspace", ".sln", ".csproj")


class Erro(Exception):
    pass


@dataclass
class Plano:
    pasta: Path
    mover: list[dict]
    lixo: list[dict]
    avisos: list[str]


def _extensao(p: Path) -> str:
    return p.suffix.lower().lstrip(".")


def _negados():
    from wisp_bot import bot
    return bot, bot._negados()


def _pasta(bruto: str | None) -> Path:
    home = Path.home().resolve()
    pasta = Path(os.path.expanduser(bruto)).resolve() if bruto else home
    if not pasta.is_dir():
        raise Erro(f"não encontrei a pasta {bruto}")
    return pasta


def _fora_do_alcance(p: Path, home: Path) -> bool:
    dentro = p.is_relative_to(home)
    partes = p.relative_to(home).parts if dentro else p.parts
    return (dentro and partes[:1] == ("Library",)) or any(x.startswith(".") for x in partes)


def _permitido(p: Path, home: Path, bot, negados) -> bool:
    if _fora_do_alcance(p, home):
        return False
    try:
        return not bot._fica_em_negado(p.resolve(), negados)
    except OSError:
        return False


def _aspas(texto: str) -> str:
    return texto.replace("\\", "\\\\").replace('"', '\\"')


def _desde(bruto: str | None) -> float | None:
    if not bruto:
        return None
    m = DURACAO.match(bruto.strip().lower())
    if not m:
        raise Erro("--desde precisa de um número e uma unidade, como 12h, 7d, 2w ou 1m")
    return time.time() - int(m.group(1)) * SEGUNDOS[m.group(2)]


def _candidatos_spotlight(runner: Runner, texto: str, pasta: Path) -> list[Path] | None:
    t = _aspas(texto)
    consulta = f'(kMDItemDisplayName == "*{t}*"cd || kMDItemTextContent == "{t}"cd)'
    r = runner.run(["mdfind", "-onlyin", str(pasta), consulta], timeout=MDFIND_S)
    if r.exit != 0 or r.timed_out:
        return None
    return [Path(linha) for linha in r.stdout.splitlines()[:MAX_CANDIDATOS] if linha.startswith("/")]


def _candidatos_por_nome(texto: str, pasta: Path, home: Path) -> list[Path]:
    achados, varridos, alvo = [], 0, texto.casefold()
    base_profundidade = len(pasta.parts)
    for raiz, dirs, arquivos in os.walk(pasta):
        r = Path(raiz)
        dirs[:] = [d for d in dirs if not _fora_do_alcance(r / d, home)]
        if len(r.parts) - base_profundidade >= MAX_PROFUNDIDADE:
            dirs[:] = []
        for nome in arquivos:
            varridos += 1
            if alvo in nome.casefold():
                achados.append(r / nome)
        if varridos >= MAX_VARRIDOS:
            break
    return achados


def _entrada(p: Path, st: os.stat_result) -> dict:
    return {"caminho": str(p), "nome": p.name, "modificado": datetime.fromtimestamp(st.st_mtime).isoformat(timespec="seconds"),
            "tamanho": st.st_size, "tipo": _extensao(p)}


def buscar(runner: Runner, texto: str, tipo: str | None, desde: str | None, pasta_bruta: str | None) -> list[dict]:
    exts = TIPOS.get(tipo.lower(), {tipo.lower().lstrip(".")}) if tipo else None
    corte = _desde(desde)
    pasta = _pasta(pasta_bruta)
    home = Path.home().resolve()
    bot, negados = _negados()
    candidatos = _candidatos_spotlight(runner, texto, pasta)
    achados = _filtrar(candidatos or [], exts, corte, home, bot, negados)
    if not achados:
        achados = _filtrar(_candidatos_por_nome(texto, pasta, home), exts, corte, home, bot, negados)
    achados.sort(key=lambda e: e["modificado"], reverse=True)
    return achados[:MAX_RESULTADOS]


def _filtrar(candidatos: list[Path], exts, corte, home: Path, bot, negados) -> list[dict]:
    out = []
    for p in candidatos:
        if exts is not None and _extensao(p) not in exts:
            continue
        try:
            st = p.stat()
        except OSError:
            continue
        if not p.is_file() or (corte is not None and st.st_mtime < corte):
            continue
        if _permitido(p, home, bot, negados):
            out.append(_entrada(p, st))
    return out


def _tamanho(n: int) -> str:
    if n < 1024:
        return f"{n} B"
    valor, unidade = float(n), "B"
    for unidade in ("KB", "MB", "GB"):
        valor /= 1024
        if valor < 1024:
            break
    return f"{valor:.1f} {unidade}".replace(".", ",")


def _linha(e: dict) -> str:
    data = datetime.fromisoformat(e["modificado"]).strftime("%d/%m/%Y")
    return f"{e['caminho']}  ({data} · {_tamanho(e['tamanho'])})"


def _grupo(p: Path) -> str:
    ext = _extensao(p)
    return next((g for g, exts in GRUPOS.items() if ext in exts), OUTROS)


def _destino_livre(pasta: Path, nome: str, reservados: set[Path]) -> Path:
    alvo = pasta / nome
    stem, suf, n = Path(nome).stem, Path(nome).suffix, 2
    while os.path.lexists(alvo) or alvo in reservados:
        alvo = pasta / f"{stem} {n}{suf}"
        n += 1
    return alvo


def _mover_sem_sobrescrever(origem: Path, destino: Path) -> None:
    if sys.platform == "darwin":
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.renamex_np(os.fsencode(origem), os.fsencode(destino), RENAME_EXCL) != 0:
            erro = ctypes.get_errno()
            raise OSError(erro, os.strerror(erro), str(destino))
        return
    os.link(origem, destino)
    os.unlink(origem)


def _mover_livre(origem: Path, destino: Path) -> Path:
    for _ in range(TENTATIVAS_NOME):
        alvo = _destino_livre(destino.parent, destino.name, set())
        try:
            _mover_sem_sobrescrever(origem, alvo)
            return alvo
        except FileExistsError:
            continue
    raise FileExistsError(f"não achei um nome livre para {destino.name}")


def _motivo_da_pasta(pasta: Path, grupo: str) -> str | None:
    alvo = pasta / grupo
    if not os.path.lexists(alvo):
        return None
    if alvo.is_symlink():
        return f"{grupo} é um atalho, não uma pasta"
    if not alvo.is_dir():
        return f"já existe um arquivo chamado {grupo}"
    if not alvo.resolve().is_relative_to(pasta.resolve()):
        return f"{grupo} aponta para fora da pasta"
    return None


def _marca_de_projeto(pasta: Path) -> str | None:
    for p in pasta.iterdir():
        if p.name in MARCAS_DE_PROJETO or p.name.endswith(SUFIXOS_DE_PROJETO):
            return p.name
    return None


def planejar(pasta_bruta: str, agora: float | None = None) -> Plano:
    pasta = _pasta(pasta_bruta)
    home = Path.home().resolve()
    if pasta == home or not pasta.is_relative_to(home) or _fora_do_alcance(pasta, home):
        raise Erro("só organizo uma pasta dentro da sua pasta pessoal (como Downloads), nunca a pasta pessoal inteira nem a Biblioteca")
    marca = _marca_de_projeto(pasta)
    if marca:
        raise Erro(f"essa pasta parece um projeto (tem {marca}) e organizar poderia quebrá-lo; só organizo pastas soltas, como Downloads, Mesa ou Documentos")
    bot, negados = _negados()
    agora = time.time() if agora is None else agora
    mover, lixo, avisos, reservados, barrados = [], [], [], set(), {}
    for p in sorted(pasta.iterdir(), key=lambda x: x.name.casefold()):
        if p.name.startswith(".") or p.is_symlink() or not p.is_file() or not _permitido(p, home, bot, negados):
            continue
        grupo = _grupo(p)
        if grupo == "Instaladores" and agora - p.stat().st_mtime > INSTALADOR_DIAS * 86400:
            lixo.append({"de": str(p)})
            continue
        if grupo not in barrados:
            barrados[grupo] = _motivo_da_pasta(pasta, grupo)
            if barrados[grupo]:
                avisos.append(f"não vou mexer nos arquivos de {grupo}: {barrados[grupo]}")
        if barrados[grupo]:
            continue
        alvo = _destino_livre(pasta / grupo, p.name, reservados)
        reservados.add(alvo)
        mover.append({"de": str(p), "para": str(alvo), "grupo": grupo})
    return Plano(pasta, mover, lixo, avisos)


def _lista(nomes: list[str]) -> str:
    mais = f" e mais {len(nomes) - MOSTRAR_POR_GRUPO}" if len(nomes) > MOSTRAR_POR_GRUPO else ""
    return ", ".join(nomes[:MOSTRAR_POR_GRUPO]) + mais


def _texto_plano(plano: Plano) -> str:
    if not plano.mover and not plano.lixo and not plano.avisos:
        return f"Nada para organizar em {plano.pasta}."
    linhas = [f"Plano para {plano.pasta} (nada foi mexido ainda):"]
    grupos: dict[str, list[dict]] = {}
    for m in plano.mover:
        grupos.setdefault(m["grupo"], []).append(m)
    for grupo, itens in grupos.items():
        linhas.append(f"- {grupo}: {len(itens)} arquivo(s): {_lista([Path(i['para']).name for i in itens])}")
    if plano.lixo:
        linhas.append(f"- Instaladores com mais de {INSTALADOR_DIAS} dias, sugeridos para o Lixo: {len(plano.lixo)}: "
                      f"{_lista([Path(i['de']).name for i in plano.lixo])}")
        linhas.append("  (só vão para o Lixo com --aplicar --lixo, e dá para recuperar de lá)")
    linhas.extend(f"- Aviso: {a}" for a in plano.avisos)
    linhas.append(f"Tipos que não reconheço vão para {OUTROS}.")
    linhas.append("Para aplicar: rode de novo com --aplicar. Dá para desfazer com `arquivos desfazer`.")
    return "\n".join(linhas)


def _para_o_lixo(runner: Runner, caminho: str) -> bool:
    if Path(TRASH).exists():
        return runner.run([TRASH, caminho], timeout=30).exit == 0
    script = 'on run argv\ntell application "Finder" to delete POSIX file (item 1 of argv)\nend run'
    return runner.run(["osascript", "-e", script, "--", caminho], timeout=30).exit == 0


def _diario_dir(paths: WispPaths) -> Path:
    return paths.state / "arquivos"


def _anotar(arquivo: Path, registro: dict) -> None:
    with arquivo.open("a", encoding="utf-8") as f:
        f.write(json.dumps(registro, ensure_ascii=False) + "\n")
        f.flush()
        os.fsync(f.fileno())


def aplicar(runner: Runner, paths: WispPaths, plano: Plano, com_lixo: bool, agora: datetime | None = None) -> dict:
    base = (agora or datetime.now()).strftime("%Y%m%d-%H%M%S")
    ts, n = base, 2
    _diario_dir(paths).mkdir(parents=True, exist_ok=True)
    while os.path.lexists(_diario_dir(paths) / f"desfazer-{ts}.json") or os.path.lexists(_diario_dir(paths) / f"desfeito-{ts}.json"):
        ts, n = f"{base}-{n}", n + 1
    diario = _diario_dir(paths) / f"desfazer-{ts}.json"
    with diario.open("x", encoding="utf-8") as f:
        f.write(json.dumps({"version": 2, "pasta": str(plano.pasta)}, ensure_ascii=False) + "\n")
        f.flush()
        os.fsync(f.fileno())
    movidos, falhas = 0, []
    for m in plano.mover:
        origem, destino = Path(m["de"]), Path(m["para"])
        try:
            if not origem.is_file() or origem.is_symlink():
                raise FileNotFoundError("o arquivo mudou ou sumiu")
            motivo = _motivo_da_pasta(plano.pasta, m["grupo"])
            if motivo:
                raise OSError(motivo)
            if not os.path.lexists(destino.parent):
                destino.parent.mkdir()
                _anotar(diario, {"criada": str(destino.parent)})
            final = _mover_livre(origem, destino)
            _anotar(diario, {"de": str(origem), "para": str(final)})
            movidos += 1
        except OSError as e:
            falhas.append({"arquivo": origem.name, "motivo": e.strerror or str(e)})
    lixo = [i["de"] for i in plano.lixo if com_lixo and _para_o_lixo(runner, i["de"])]
    if not movidos and diario.read_text("utf-8").count("\n") == 1:
        diario.unlink()
        ts = None
    return {"ts": ts, "movidos": movidos, "lixo": len(lixo), "falhas": falhas}


def _ler_diario(arquivo: Path) -> tuple[list[dict], list[str]]:
    try:
        linhas = [json.loads(l) for l in arquivo.read_text("utf-8").splitlines() if l.strip()]
        if not linhas or linhas[0]["version"] != 2:
            raise ValueError("cabeçalho")
        movidos = [{"de": str(l["de"]), "para": str(l["para"])} for l in linhas[1:] if "de" in l]
        criadas = [str(l["criada"]) for l in linhas[1:] if "criada" in l]
    except (ValueError, KeyError, TypeError, AttributeError) as e:
        raise Erro(f"o registro {arquivo.name} está danificado e não mexi em nada") from e
    return movidos, criadas


def desfazer(paths: WispPaths, ts: str | None) -> dict:
    pasta = _diario_dir(paths)
    diarios = sorted(pasta.glob("desfazer-*.json"), key=lambda d: d.stem) if pasta.is_dir() else []
    if ts:
        diarios = [d for d in diarios if d.name == f"desfazer-{ts}.json"]
    if not diarios:
        raise Erro("não achei nada para desfazer" + (f" com o código {ts}" if ts else ""))
    arquivo = diarios[-1]
    movidos, criadas = _ler_diario(arquivo)
    voltaram, nao = 0, []
    for m in reversed(movidos):
        feito, original = Path(m["para"]), Path(m["de"])
        if not feito.is_file() or feito.is_symlink():
            nao.append({"arquivo": original.name, "motivo": "não está mais onde o Wisp deixou"})
            continue
        if os.path.lexists(original):
            nao.append({"arquivo": original.name, "motivo": "já existe algo no lugar de antes"})
            continue
        try:
            original.parent.mkdir(parents=True, exist_ok=True)
            _mover_sem_sobrescrever(feito, original)
            voltaram += 1
        except OSError as e:
            nao.append({"arquivo": original.name, "motivo": e.strerror or str(e)})
    for criada in criadas:
        try:
            Path(criada).rmdir()
        except OSError:
            pass
    arquivo.rename(arquivo.with_name(arquivo.name.replace("desfazer-", "desfeito-", 1)))
    return {"ts": arquivo.stem.removeprefix("desfazer-"), "voltaram": voltaram, "nao_restaurados": nao}


def _cmd_buscar(a: argparse.Namespace) -> int:
    achados = buscar(SubprocessRunner(), a.texto, a.tipo, a.desde, a.pasta)
    if a.json:
        print(json.dumps(achados, ensure_ascii=False))
    elif achados:
        print("\n".join(_linha(e) for e in achados))
    else:
        print(f'Não achei nada para "{a.texto}".')
    return 0


def _cmd_organizar(a: argparse.Namespace) -> int:
    plano = planejar(a.pasta)
    if not a.aplicar:
        if a.json:
            print(json.dumps({"pasta": str(plano.pasta), "mover": plano.mover, "lixo": plano.lixo, "avisos": plano.avisos,
                              "aplicado": False}, ensure_ascii=False))
        else:
            print(_texto_plano(plano))
        return 0
    res = aplicar(SubprocessRunner(), WispPaths.current(), plano, a.lixo)
    if a.json:
        print(json.dumps({**res, "aplicado": True}, ensure_ascii=False))
        return 1 if res["falhas"] else 0
    partes = [f"Movi {res['movidos']} arquivo(s) em {plano.pasta}."]
    if res["lixo"]:
        partes.append(f"{res['lixo']} instalador(es) antigo(s) foram para o Lixo.")
    if res["falhas"]:
        partes.append(f"Não consegui mover {len(res['falhas'])}: {_lista([f['arquivo'] + ' (' + f['motivo'] + ')' for f in res['falhas']])}.")
    if res["ts"]:
        partes.append(f"Para desfazer: arquivos desfazer {res['ts']}")
    print(" ".join(partes))
    return 1 if res["falhas"] else 0


def _cmd_desfazer(a: argparse.Namespace) -> int:
    res = desfazer(WispPaths.current(), a.ts)
    if a.json:
        print(json.dumps(res, ensure_ascii=False))
        return 0
    extra = ""
    if res["nao_restaurados"]:
        extra = (f" Não voltaram {len(res['nao_restaurados'])}: "
                 f"{_lista([f['arquivo'] + ' (' + f['motivo'] + ')' for f in res['nao_restaurados']])}.")
    print(f"Desfiz: {res['voltaram']} arquivo(s) voltaram ao lugar de antes.{extra}")
    return 0


def add_parser(sub) -> argparse.ArgumentParser:
    arq = sub.add_parser("arquivos", help="find and organize the user's files")
    cmds = arq.add_subparsers(dest="arquivos_cmd", required=True)
    p = cmds.add_parser("buscar")
    p.add_argument("texto")
    p.add_argument("--tipo")
    p.add_argument("--desde")
    p.add_argument("--pasta")
    p.add_argument("--json", action="store_true")
    p.set_defaults(f=_cmd_buscar)
    p = cmds.add_parser("organizar")
    p.add_argument("pasta")
    p.add_argument("--aplicar", action="store_true")
    p.add_argument("--lixo", action="store_true", help="with --aplicar, also move old installers to the Trash")
    p.add_argument("--json", action="store_true")
    p.set_defaults(f=_cmd_organizar)
    p = cmds.add_parser("desfazer")
    p.add_argument("ts", nargs="?")
    p.add_argument("--json", action="store_true")
    p.set_defaults(f=_cmd_desfazer)
    return arq


def run(a: argparse.Namespace) -> int:
    try:
        return a.f(a)
    except Erro as e:
        print(str(e), file=sys.stderr)
        return 2
    except OSError as e:
        print(f"não consegui mexer nos arquivos: {e.strerror or type(e).__name__}", file=sys.stderr)
        return 1
