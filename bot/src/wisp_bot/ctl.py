"""Fila de controle dos topicos: fechar, soltar para o terminal, adotar do terminal.

Mesmo padrao do abrir.py — arquivo em disco, o bot consome. So o bot mexe no
topics.json e fala com o Telegram; quem quer algo (a CLI `wisp topic`, uma sessao
no terminal) deixa um pedido aqui e espera o resultado em done/<id>.json.

  <state_dir>/ctl/<id>.json        pedido {id, op, ...args}
  <state_dir>/ctl/done/<id>.json   resultado {ok, ...} ou {ok: false, erro}

Ops: encerrar {thread} · soltar {thread, destino} · adotar {session_id, cwd, nome,
origem_host} · falar {thread, texto, origem?} (poe o texto no topico e o agente responde). `listar` nao e op: a CLI le as notas do brain direto.

O PC nunca alcanca o Mac. A fila do PC e servida assim: se o PC le o Telegram, o
bot dele consome a fila local; se o Mac le, o bot do Mac drena a fila do PC por ssh
(drenar_pc) e devolve o done para la (escrever_done_pc).
"""
from __future__ import annotations
import base64, json, re, subprocess, time, uuid
from pathlib import Path

from . import hosting, sessao

DIR = hosting.DIR / "ctl"
DONE = DIR / "done"


def destinos() -> tuple[str, ...]:
    """Para que terminal um topico pode ir: em `solo` so o desta maquina."""
    return ("terminal-mac", "terminal-pc") if hosting.MODO == "pair" else (f"terminal-{hosting.HOST}",)


FRESCO_S = 30                  # host-state mais velho que isto = bot parado
EXPIRA_S = 300                 # pedido mais velho que isto o bot descarta
_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def _gravar(f: Path, dados: dict) -> None:
    f.parent.mkdir(parents=True, exist_ok=True)
    tmp = f.with_suffix(".tmp")
    tmp.write_text(json.dumps(dados, ensure_ascii=False), "utf-8")
    tmp.replace(f)                     # o bot nunca le um pedido pela metade


def novo_id() -> str:
    return f"{int(time.time())}-{uuid.uuid4().hex[:6]}"


def pedir(op: str, **args) -> str:
    """Fila local. Devolve o id para esperar o resultado."""
    id_ = novo_id()
    _gravar(DIR / f"{id_}.json", {"id": id_, "op": op, **args, "at": time.time()})
    return id_


def expirado(d: dict) -> bool:
    """`_idade` (drenar_pc) e a idade medida no relogio de quem pediu; sem ela, o relogio local."""
    idade = d.get("_idade")
    if isinstance(idade, (int, float)):
        return idade > EXPIRA_S
    at = d.get("at")
    return isinstance(at, (int, float)) and time.time() - at > EXPIRA_S


def pendentes() -> list[dict]:
    if not DIR.is_dir():
        return []
    out = []
    for f in sorted(DIR.glob("*.json")):
        try:
            d = json.loads(f.read_text("utf-8"))
        except (json.JSONDecodeError, OSError):
            f.unlink(missing_ok=True)
            continue
        if not isinstance(d, dict) or not _ID.match(str(d.setdefault("id", f.stem))):
            f.unlink(missing_ok=True)          # id vira nome de arquivo e vai para script: so o seguro
            continue
        d["_file"] = str(f)
        out.append(d)
    return out


def consumir(p: dict) -> None:
    Path(p["_file"]).unlink(missing_ok=True)


def gravar_done(id_: str, resultado: dict) -> None:
    _gravar(DONE / f"{id_}.json", resultado)


def ler_done(id_: str, apagar: bool = True) -> dict | None:
    f = DONE / f"{id_}.json"
    try:
        d = json.loads(f.read_text("utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if apagar:
        f.unlink(missing_ok=True)
    return d


def limpar(max_idade_s: float = 86400) -> None:
    """Resultado que ninguem foi buscar nao fica para sempre."""
    if DONE.is_dir():
        for f in DONE.glob("*.json"):
            try:
                if time.time() - f.stat().st_mtime > max_idade_s:
                    f.unlink()
            except OSError:
                pass


# ---- roteamento: para qual fila vai o pedido ----

def rota() -> str:
    """'local' ou 'pc'. No PC e sempre local (se o Mac le, ele drena esta fila).
    No Mac, local se o bot daqui le o Telegram agora; senao a fila do PC, por ssh."""
    if hosting.MODO != "pair" or hosting.HOST == "pc":
        return "local"
    st = hosting.ler_estado_local()
    if st.get("state") == "active" and time.time() - int(st.get("ts", 0)) <= FRESCO_S:
        return "local"
    return "pc"


def pc_run(script: str, timeout: float = 20) -> tuple[int, str]:
    """Roda `script` no PC (stdin). Sincrono: a CLI nao tem loop; o bot chama
    por asyncio.to_thread."""
    argv = hosting.pc_argv()
    if argv is None:
        return 2, ""
    try:
        r = subprocess.run(argv, input=script.encode(), capture_output=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError):
        return 124, ""
    return r.returncode, r.stdout.decode("utf-8", "replace")


def _b64(d: dict) -> str:
    return base64.b64encode(json.dumps(d, ensure_ascii=False).encode()).decode()


def _gravar_no_pc(rel: str, nome: str, dados: dict, at_do_pc: bool = False) -> bool:
    """at_do_pc: carimba `at` com o relogio do PC (o relogio do Mac nao vale la)."""
    if at_do_pc:
        grava = r'''printf '%s,"at":%s}' "${j%\}}" "$(date +%s)" > "$d/NOME.tmp" && mv "$d/NOME.tmp" "$d/NOME.json"'''
        corpo = f'j=$(echo {_b64(dados)} | base64 -d)\n' + grava.replace("NOME", nome) + "\n"
    else:
        corpo = f'echo {_b64(dados)} | base64 -d > "$d/{nome}.tmp" && mv "$d/{nome}.tmp" "$d/{nome}.json"\n'
    script = f'd="{hosting.DIR_REMOTO}/{rel}"; mkdir -p "$d"\n' + corpo
    return pc_run(script)[0] == 0


def pedir_pc(op: str, **args) -> str:
    id_ = novo_id()
    if not _gravar_no_pc("ctl", id_, {"id": id_, "op": op, **args}, at_do_pc=True):
        raise RuntimeError("nao consegui deixar o pedido na fila do PC (ssh)")
    return id_


def escrever_done_pc(id_: str, resultado: dict) -> bool:
    return _gravar_no_pc("ctl/done", id_, resultado) if _ID.match(id_) else False


def ler_done_pc(id_: str) -> dict | None:
    rc, out = pc_run(f'f="{hosting.DIR_REMOTO}/ctl/done/{id_}.json"\n'
                     '[ -f "$f" ] && cat "$f" && rm -f "$f"\n', timeout=15)
    try:
        return json.loads(out) if rc == 0 and out.strip() else None
    except json.JSONDecodeError:
        return None


def drenar_pc(ctl: bool = True, pedidos: bool = True) -> tuple[list[dict], list[dict], bool]:
    """Le (e apaga) a fila de controle do PC; le (sem apagar) os pedidos de sessao.
    Devolve (ops, pedidos, ssh_ok). Apagar o pedido de sessao e do chamador, depois
    de empurrar o jsonl."""
    partes = ['echo "NOW $(date +%s)"',
              f'cd "{hosting.DIR_REMOTO}" 2>/dev/null || exit 0']
    if ctl:
        partes.append('for f in ctl/*.json; do [ -f "$f" ] || continue; '
                      'echo "CTL $(basename "$f" .json) $(base64 -w0 < "$f")"; rm -f "$f"; done')
    if pedidos:
        partes.append('for f in sessao-pedidos/*.json; do [ -f "$f" ] || continue; '
                      'echo "PED $(basename "$f" .json) $(base64 -w0 < "$f")"; done')
    rc, out = pc_run("\n".join(partes) + "\n", timeout=15)
    ops, peds = [], []
    pc_now = None
    for linha in out.splitlines():
        tipo, _, resto = linha.partition(" ")
        if tipo == "NOW":
            try:
                pc_now = int(resto.strip())
            except ValueError:
                pass
            continue
        nome, _, b64 = resto.partition(" ")
        if tipo not in ("CTL", "PED") or not _ID.match(nome):
            continue
        try:
            d = json.loads(base64.b64decode(b64))
        except (ValueError, json.JSONDecodeError):
            continue
        if not isinstance(d, dict):
            continue
        d["id"] = nome
        if pc_now is not None and isinstance(d.get("at"), (int, float)):
            d["_idade"] = pc_now - d["at"]         # relogio do PC contra relogio do PC
        (ops if tipo == "CTL" else peds).append(d)
    return ops, peds, rc == 0


def apagar_pedido_pc(session_id: str) -> None:
    if sessao.valido(session_id):
        pc_run(f'rm -f "$HOME/{sessao.PEDIDOS_REL}/{session_id}.json"\n')


# ---- lado de quem pede (CLI) ----

def enfileirar(op: str, **args) -> tuple[str, str]:
    """(id, rota) — a rota decide onde esperar o done."""
    r = rota()
    return (pedir(op, **args) if r == "local" else pedir_pc(op, **args)), r


def cancelar(id_: str, r: str) -> None:
    """A CLI desistiu de esperar: tira o proprio pedido da fila para o bot nao agir tarde."""
    if not _ID.match(id_):
        return
    if r == "local":
        (DIR / f"{id_}.json").unlink(missing_ok=True)
    else:
        pc_run(f'rm -f "{hosting.DIR_REMOTO}/ctl/{id_}.json"\n', timeout=15)


def aguardar(id_: str, r: str, timeout: float) -> dict | None:
    fim = time.time() + timeout
    while time.time() < fim:
        d = ler_done(id_) if r == "local" else ler_done_pc(id_)
        if d is not None:
            return d
        time.sleep(1.0 if r == "local" else 3.0)
    return None
