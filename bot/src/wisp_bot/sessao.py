"""A sessao do Claude atravessando Mac <-> PC.

O jsonl da sessao mora em ~/.claude/projects/<slug>/<session_id>.jsonl, onde slug e o
cwd absoluto com tudo que nao e letra/numero trocado por "-". Copiar o jsonl para o
slug do cwd onde se vai retomar basta para `claude --resume <id>` recuperar o contexto
inteiro, mesmo que os campos "cwd" la dentro apontem para um caminho que nao existe
nesta maquina (verificado 14/10).

Quem inicia e SEMPRE o Mac (o PC nao alcanca o Mac). A copia vai so pelo canal ssh:
a sessao pode ter segredo, entao nunca passa por git nem pelo brain. O shell remoto
e o cmd.exe, que come binario: o arquivo viaja em base64, em fluxo (nunca inteiro na
memoria), e a integridade e conferida por sha256.

O PC nao puxa; pede. Ele deixa <state_dir>/sessao-pedidos/<id>.json e o bot do
Mac, que olha o PC a cada tick de hosting, empurra o jsonl.
"""
from __future__ import annotations
import base64, hashlib, json, logging, os, re, shlex, shutil, signal, subprocess, threading, time, uuid
from pathlib import Path

from . import hosting

log = logging.getLogger("wisp.sessao")

PROJETOS = Path.home() / ".claude" / "projects"
PEDIDOS = hosting.DIR / "sessao-pedidos"
PEDIDOS_REL = f"{hosting.DIR_REMOTO_REL}/sessao-pedidos"
TIMEOUT_S = 600
_ID = re.compile(r"^[0-9A-Za-z-]{8,64}$")
_FIM = "WISP_SESSAO_EOF"


def valido(session_id: str) -> bool:
    """O id vai para dentro de um script bash: so passa o que parece um uuid."""
    return bool(_ID.match(session_id or ""))


def slug(cwd: str) -> str:
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def caminho(session_id: str, cwd: str) -> Path:
    return PROJETOS / slug(cwd) / f"{session_id}.jsonl"


def achar_local(session_id: str) -> Path | None:
    """O jsonl em qualquer slug desta maquina (o cwd pode ter mudado de caminho). Com copias
    em mais de um slug devolve a MAIOR (jsonl so cresce: maior = mais completa)."""
    copias = sorted(PROJETOS.glob(f"*/{session_id}.jsonl"))
    return max(copias, key=lambda p: p.stat().st_size) if copias else None


def mais_nova(cwd: str) -> str | None:
    """session_id do jsonl mais recente do slug do cwd."""
    d = PROJETOS / slug(cwd)
    arqs = sorted(d.glob("*.jsonl"), key=lambda p: p.stat().st_mtime) if d.is_dir() else []
    return arqs[-1].stem if arqs else None


VIVA_S = 120


def _outras_copias(session_id: str, manter: Path) -> None:
    """Uma copia por maquina: apaga o mesmo id nos outros slugs. So chamar com `manter` existente."""
    if not manter.exists():
        return
    for p in PROJETOS.glob(f"*/{session_id}.jsonl"):
        # escrita nos ultimos 2 min = pode ser um claude vivo nela: apagar perderia o que ele grava
        if p != manter and time.time() - p.stat().st_mtime > VIVA_S:
            p.unlink(missing_ok=True)


def _trocar_sem_encolher(tmp: Path, alvo: Path) -> None:
    """tmp vira alvo, a menos que alvo ja seja maior: nenhum caminho encolhe uma sessao."""
    if alvo.exists() and alvo.stat().st_size > tmp.stat().st_size:
        tmp.unlink(missing_ok=True)
        raise RuntimeError("copia local mais nova")
    tmp.replace(alvo)


def _copiar(origem: Path, destino: Path) -> None:
    destino.parent.mkdir(parents=True, exist_ok=True)
    tmp = destino.with_suffix(".tmp")
    shutil.copyfile(origem, tmp)
    tmp.replace(destino)


def garantir_local(session_id: str, cwd: str) -> bool:
    """Deixa o jsonl no slug do cwd em que vai ser retomado. False = nao ha jsonl aqui."""
    if not valido(session_id):
        return False
    alvo = caminho(session_id, cwd)
    copias = [p for p in PROJETOS.glob(f"*/{session_id}.jsonl")]
    if not copias:
        return False
    nova = max(copias, key=lambda p: p.stat().st_mtime)
    if not alvo.exists() or alvo.stat().st_mtime < nova.stat().st_mtime:
        _copiar(nova, alvo)
    _outras_copias(session_id, alvo)
    return True


def _sha(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for bloco in iter(lambda: f.read(1 << 20), b""):
            h.update(bloco)
    return h.hexdigest()


def _matar_grupo(p: subprocess.Popen) -> None:
    """SIGKILL no grupo do processo (ele nasceu com start_new_session): ssh e filhos nao sobram."""
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def _matar_em(p: subprocess.Popen, s: float) -> threading.Timer:
    t = threading.Timer(s, _matar_grupo, (p,))
    t.daemon = True
    t.start()
    return t


def _tmp_unico(alvo: Path) -> Path:
    """Nome de tmp so deste escritor: dois buscar_do_pc da mesma sessao (bot e espelho) nao dividem o arquivo."""
    return alvo.with_name(f"{alvo.name}.{os.getpid()}.{uuid.uuid4().hex[:8]}.tmp")


def sem_par() -> str:
    """Por que nao ha ssh ao PC: modo solo, ou o arquivo do par que nao da host/usuario."""
    if hosting.MODO != "pair":
        return "modo solo: há uma máquina só, não há outra de onde trazer a sessão"
    return f"config do PC ausente ou incompleta ({hosting.PC_CFG})"


def ssh_pc(script: str, prazo: float) -> tuple[int, str]:
    """Um ssh ao PC com o script pelo stdin, no proprio grupo; no estouro mata o grupo inteiro. (124, "") = estourou."""
    argv = hosting.pc_argv()
    if argv is None:
        return 2, ""
    try:
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             start_new_session=True)
    except OSError:
        return 255, ""
    try:
        out, _ = p.communicate(script.encode(), timeout=prazo)
    except subprocess.TimeoutExpired:
        _matar_grupo(p)
        p.communicate()
        return 124, ""
    return p.returncode, out.decode("utf-8", "replace")


TRAZER_S = 45.0                  # o assumir do Wisp tem 75 s no total; o pull da sessao cabe aqui dentro


def trazer_se_maior(session_id: str, cwd_local: str, prazo: float = TRAZER_S) -> str:
    """Mac: traz o jsonl do PC se a copia de la e maior. 'local' | 'trazida' | 'falhou'. Bloqueia (ssh)."""
    if not valido(session_id):
        return "local"
    t0 = time.monotonic()
    rc, out = ssh_pc(f'stat -c %s "$HOME"/.claude/projects/*/{session_id}.jsonl 2>/dev/null | sort -n | tail -1\n',
                     min(10.0, prazo))
    tam_pc = int(out.strip()) if rc == 0 and out.strip().isdigit() else 0
    if tam_pc <= tamanho_local(session_id):
        return "local"
    try:
        buscar_do_pc(session_id, cwd_local, timeout_s=max(1.0, prazo - (time.monotonic() - t0)))
    except (RuntimeError, OSError) as e:
        log.warning("sessao %s nao veio do PC: %s", session_id, e)
        return "falhou"
    return "trazida"


def buscar_do_pc(session_id: str, cwd_local: str, timeout_s: float = TIMEOUT_S) -> Path:
    """PC -> Mac. Levanta RuntimeError com o motivo se nao deu. timeout_s: teto do ssh (mata o grupo).
    A copia do PC vence a do Mac: so se busca quando a nota diz session_host=pc."""
    if not valido(session_id):
        raise RuntimeError(f"session_id invalido: {session_id!r}")
    argv = hosting.pc_argv()
    if argv is None:
        raise RuntimeError(sem_par())
    script = (f'f=$(ls -t "$HOME"/.claude/projects/*/{session_id}.jsonl 2>/dev/null | head -1)\n'
              '[ -n "$f" ] || exit 3\n'
              'base64 -w 76 < "$f"\n'
              'echo "SHA:$(sha256sum < "$f" | cut -d" " -f1)"\n')
    alvo = caminho(session_id, cwd_local)
    alvo.parent.mkdir(parents=True, exist_ok=True)
    tmp = _tmp_unico(alvo)
    h = hashlib.sha256()
    sha_pc = ""
    p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    timer = _matar_em(p, max(1.0, timeout_s))
    try:
        p.stdin.write(script.encode())
        p.stdin.close()
        with tmp.open("wb") as f:
            for linha in p.stdout:                 # em fluxo: cada linha de 76 chars e completa
                linha = linha.strip()
                if linha.startswith(b"SHA:"):
                    sha_pc = linha[4:].decode()
                elif linha:
                    bloco = base64.b64decode(linha, validate=True)
                    h.update(bloco)
                    f.write(bloco)
        rc = p.wait()
    except Exception as e:                     # base64 ruim (binascii.Error), disco, pipe
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"copia do PC corrompida ({type(e).__name__})") from e
    finally:
        timer.cancel()
        if p.poll() is None:
            _matar_grupo(p)
    if rc == 3:
        tmp.unlink(missing_ok=True)
        raise RuntimeError("jsonl nao esta no PC")
    if rc != 0 or not sha_pc or sha_pc != h.hexdigest():
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"copia do PC incompleta (rc={rc})")
    _trocar_sem_encolher(tmp, alvo)
    _outras_copias(session_id, alvo)
    return alvo


def enviar_ao_pc(session_id: str, cwd_pc: str, timeout_s: float = TIMEOUT_S) -> None:
    """Mac -> PC. cwd_pc pode comecar com "~" (resolve no HOME do PC). timeout_s limita este envio."""
    if not valido(session_id):
        raise RuntimeError(f"session_id invalido: {session_id!r}")
    origem = achar_local(session_id)
    if origem is None:
        raise RuntimeError("jsonl nao esta nesta maquina")
    argv = hosting.pc_argv()
    if argv is None:
        raise RuntimeError(sem_par())
    cabeca = (
        "set -e\n"
        f"cwd={shlex.quote(cwd_pc)}\n"
        'case "$cwd" in "~") cwd="$HOME";; "~/"*) cwd="$HOME/${cwd#"~/"}";; esac\n'
        'slug=$(printf %s "$cwd" | sed "s#[^A-Za-z0-9]#-#g")\n'
        'd="$HOME/.claude/projects/$slug"; mkdir -p "$d"\n'
        f'f="$d/{session_id}.jsonl"\n'
        f"base64 -d > \"$f.tmp\" <<'{_FIM}'\n")
    cauda = (f"{_FIM}\n"
             f'echo "{_sha(origem)}  $f.tmp" | sha256sum -c >/dev/null\n'
             'mv "$f.tmp" "$f"\n'
             f'for o in "$HOME"/.claude/projects/*/{session_id}.jsonl; do [ "$o" = "$f" ] && continue; [ -n "$(find "$o" -mmin -2 2>/dev/null)" ] && continue; rm -f "$o"; done\n'
             'echo OK\n')
    p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    timer = _matar_em(p, max(1.0, timeout_s))
    try:
        p.stdin.write(cabeca.encode())
        with origem.open("rb") as f:
            # multiplo de 57 bytes = linhas de 76 chars sem padding no meio
            for bloco in iter(lambda: f.read(57 * 4096), b""):
                p.stdin.write(base64.encodebytes(bloco))
        p.stdin.write(cauda.encode())
        p.stdin.close()
        out = p.stdout.read().decode("utf-8", "replace")
        rc = p.wait()
    except BrokenPipeError:
        out, rc = "", 1
    finally:
        timer.cancel()
        if p.poll() is None:
            _matar_grupo(p)
    if rc != 0 or "OK" not in out.split():
        raise RuntimeError(f"envio ao PC falhou (rc={rc})")


def pedir(session_id: str, cwd_pc: str) -> Path:
    """No PC: pede ao Mac que empurre a sessao para ca."""
    PEDIDOS.mkdir(parents=True, exist_ok=True)
    f = PEDIDOS / f"{session_id}.json"
    tmp = f.with_suffix(".tmp")
    tmp.write_text(json.dumps({"session_id": session_id, "cwd_pc": cwd_pc,
                               "at": time.time()}), "utf-8")
    tmp.replace(f)
    return f


# ---- a nota do topico manda na sessao: o host que assume retoma a MESMA, nao abre outra ----

ESPERA_PEDIDO_S = 45.0           # o Mac olha o PC a cada 30s ocioso; 20s perdia a janela
EMPURRADAS = hosting.DIR / "empurradas.json"    # sid -> mtime do que o PC ja tem
ESPELHO = hosting.DIR / "espelho.json"          # sid -> mtime (no PC) do que o Mac ja copiou


def tamanho_local(session_id: str) -> int:
    p = achar_local(session_id) if valido(session_id) else None
    return p.stat().st_size if p else 0


def a_trazer(m: dict, local_sid: str, host: str, tam_local: int) -> str | None:
    """sid que a nota manda usar e que este host ainda nao tem em dia, ou None.
    tam_local = bytes do jsonl desta maquina (0 = nao tem). A nota guarda o tamanho do jsonl
    quando o turno acabou (session_size): copia local menor = defasada."""
    sid = m.get("session_id", "")
    if not valido(sid) or m.get("status") == "terminal":
        return None
    if m.get("session_started") == "false":
        return sid if sid != local_sid else None       # sessao nova, sem jsonl: so apontar
    if sid == local_sid and m.get("session_host", host) == host:
        return None
    tam_nota = int(m["session_size"]) if str(m.get("session_size", "")).isdigit() else 0
    if sid == local_sid and tam_local and tam_local >= tam_nota:
        return None                                    # as duas pontas tem copia igual
    return sid


def trazer(sid: str, cwd: str, m: dict, host: str) -> bool:
    """Deixa o jsonl da sessao `sid` pronto aqui, em dia com a nota. False = nao deu (cai no
    CONTINUACAO/RETORNO). Bloqueia (ssh, espera): chamar por asyncio.to_thread."""
    tam_nota = int(m["session_size"]) if str(m.get("session_size", "")).isdigit() else 0
    dono = m.get("session_host", "")
    tam = tamanho_local(sid)
    if tam and (tam >= tam_nota > 0 or dono in ("", host)):
        try:
            return garantir_local(sid, cwd)            # a copia daqui ja e a mais nova
        except OSError as e:
            log.warning("sessao %s: copia local falhou: %s", sid, e)
            return False
    try:
        if host == "mac" and dono == "pc":
            buscar_do_pc(sid, cwd)
            return True
        if host == "pc" and dono == "mac":
            t0 = time.time()
            pedir(sid, _portavel(cwd))
            while time.time() - t0 < ESPERA_PEDIDO_S:
                p = achar_local(sid)
                if p and ((tam_nota and p.stat().st_size >= tam_nota)
                          or (not tam_nota and p.stat().st_mtime >= t0)):
                    return garantir_local(sid, cwd)
                time.sleep(1)
            log.warning("sessao %s: o Mac nao empurrou em %ds", sid, int(ESPERA_PEDIDO_S))
            return False
    except (RuntimeError, OSError) as e:      # OSError: disco, copia, ssh nao abriu
        log.warning("sessao %s: nao trouxe de %s: %s", sid, dono, e)
        return False
    try:
        return garantir_local(sid, cwd)                # dono == este host mas o store nao a tinha
    except OSError as e:
        log.warning("sessao %s: copia local falhou: %s", sid, e)
        return False


def _portavel(cwd: str) -> str:
    home = str(Path.home())
    return "~" + cwd[len(home):] if cwd == home or cwd.startswith(home + "/") else cwd


def _json(p: Path) -> dict:
    try:
        d = json.loads(p.read_text("utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _gravar_json(p: Path, d: dict) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(d), "utf-8")
    tmp.replace(p)


def mudadas(candidatas: dict[str, tuple[str, float]], registro: dict) -> list[tuple[str, str]]:
    """candidatas: sid -> (cwd, mtime atual). Devolve (sid, cwd) dos que mudaram desde o registro,
    do mais recente para o mais antigo."""
    novas = [(mt, sid, cwd) for sid, (cwd, mt) in candidatas.items() if mt > float(registro.get(sid, 0))]
    return [(sid, cwd) for _, sid, cwd in sorted(novas, reverse=True)]


def pendentes(candidatas: dict[str, str]) -> list[tuple[str, str]]:
    """(sid, cwd) das candidatas cujo jsonl local mudou desde o ultimo envio ao PC."""
    reg = _json(EMPURRADAS)
    return mudadas(_com_mtime(candidatas), reg)


def _com_mtime(candidatas: dict[str, str]) -> dict[str, tuple[str, float]]:
    out = {}
    for sid, cwd in candidatas.items():
        p = achar_local(sid)
        if p:
            out[sid] = (cwd, p.stat().st_mtime)
    return out


def empurrar_mudadas(candidatas: dict[str, str], prazo_s: float) -> int:
    """Mac -> PC antes de ceder a leitura: manda as sessoes que mudaram desde o ultimo envio.
    candidatas: sid -> cwd. Para ao estourar o prazo; cada envio tambem respeita o que resta
    dele. Devolve quantas foram."""
    fim, feitas = time.monotonic() + prazo_s, 0
    reg = _json(EMPURRADAS)
    com_mtime = _com_mtime(candidatas)
    for sid, cwd in mudadas(com_mtime, reg):
        resta = fim - time.monotonic()
        if resta <= 0:
            log.info("handover: prazo de %ds estourou; o resto vai no pedido do PC", int(prazo_s))
            break
        try:
            enviar_ao_pc(sid, _portavel(cwd), timeout_s=resta)
        except (RuntimeError, OSError) as e:
            log.warning("handover: %s nao foi ao PC: %s", sid, e)
            continue
        reg[sid] = com_mtime[sid][1]
        _gravar_json(EMPURRADAS, reg)
        feitas += 1
    return feitas


def mtimes_no_pc(sids: list[str]) -> dict[str, tuple[float, int]]:
    """(mtime epoch do PC, bytes) do jsonl de cada sid, numa chamada ssh so. {} se o PC nao respondeu."""
    sids = [s for s in sids if valido(s)]
    argv = hosting.pc_argv()
    if not sids or argv is None:
        return {}
    script = "".join(f'stat -c "%n %Y %s" "$HOME"/.claude/projects/*/{s}.jsonl 2>/dev/null\n' for s in sids)
    try:
        r = subprocess.run(argv, input=script.encode(), capture_output=True, timeout=20)
    except (subprocess.TimeoutExpired, OSError):
        return {}
    out: dict[str, tuple[float, int]] = {}
    for linha in r.stdout.decode("utf-8", "replace").splitlines():
        resto, _, tam = linha.strip().rpartition(" ")
        nome, _, mt = resto.rpartition(" ")
        sid = nome.rsplit("/", 1)[-1].removesuffix(".jsonl")
        if valido(sid) and mt.isdigit() and tam.isdigit():
            ant = out.get(sid, (0.0, 0))
            out[sid] = (max(ant[0], float(mt)), max(ant[1], int(tam)))
    return out


DIVERGE_FOLGA_S = 5.0            # NTP nos dois: relogios diferem pouco


def divergiu(tam_pc: int, mt_pc: float, copias_locais: list[tuple[int, float]]) -> bool:
    """O Mac gravou numa copia menor DEPOIS da ultima gravacao do PC: os dois cresceram da mesma
    base. Tamanho sozinho escolheria um vencedor e perderia o ramo do outro."""
    return any(tam < tam_pc and mt > mt_pc + DIVERGE_FOLGA_S for tam, mt in copias_locais)


def deve_espelhar(meta: dict | None, tam_pc: int, copias_locais: list[tuple[int, float]], agora: float,
                  mt_pc: float | None = None) -> bool:
    """So copia PC -> Mac se a copia do PC e estritamente mais nova que toda copia daqui.
    copias_locais: (bytes, mtime) de cada jsonl do sid neste Mac. jsonl so cresce: tamanho manda.
    mt_pc (mtime da copia do PC): com ele, copia daqui gravada depois = divergencia, nao espelha."""
    m = meta or {}
    if m.get("status") == "terminal" or str(m.get("onde", "")).startswith("terminal"):
        return False                                   # no terminal: ninguem espelha por cima
    if m.get("session_host") == "mac":
        return False                                   # o Mac e o dono
    for tam, mt in copias_locais:
        if tam >= tam_pc or agora - mt <= VIVA_S:      # igual/maior, ou claude vivo gravando
            return False
    if mt_pc is not None and divergiu(tam_pc, mt_pc, copias_locais):
        return False
    return True


def espelhar_do_pc(candidatas: dict[str, str], metas: dict[str, dict | None] | None = None) -> int:
    """PC -> Mac enquanto o PC le o Telegram: copia o que mudou la desde a ultima copia, para
    o Mac ja ter a sessao quando o PC desligar. candidatas: sid -> cwd local. metas: sid -> nota
    do topico (dona/terminal nao se espelha). Devolve quantas."""
    pc = mtimes_no_pc(list(candidatas))
    reg = _json(ESPELHO)
    feitas, agora = 0, time.time()
    for sid, cwd in mudadas({s: (candidatas[s], mt) for s, (mt, _) in pc.items()}, reg):
        locais = [(p.stat().st_size, p.stat().st_mtime) for p in PROJETOS.glob(f"*/{sid}.jsonl")]
        if divergiu(pc[sid][1], pc[sid][0], locais):
            log.warning("espelho: %s DIVERGIU (o Mac gravou depois do PC); nao copio por cima", sid)
            reg[sid] = pc[sid][0]                  # avisa uma vez por mudanca do PC, nao a cada tick
            _gravar_json(ESPELHO, reg)
            continue
        if not deve_espelhar((metas or {}).get(sid), pc[sid][1], locais, agora):
            continue
        try:
            buscar_do_pc(sid, cwd)
        except (RuntimeError, OSError) as e:
            log.warning("espelho: %s nao veio do PC: %s", sid, e)
            continue
        reg[sid] = pc[sid][0]
        _gravar_json(ESPELHO, reg)
        feitas += 1
    return feitas


# ---- turno do Mac em voo na hora da cessao: o PC espera o jsonl inteiro antes de retomar ----

EM_VOO = hosting.DIR / "em-voo-mac.json"    # no PC: key -> {"sid", "ts"}
EM_VOO_MAX_S = 1800.0            # entrada mais velha que isto e lixo (Mac caiu no meio do turno)
EM_VOO_ESPERA_S = 600.0


def em_voo_vivo(marcador: dict, key: str, agora: float, max_s: float = EM_VOO_MAX_S) -> dict | None:
    """A entrada do marcador para `key` se ainda vale (bem formada e com menos de max_s), senao None."""
    e = marcador.get(key) if isinstance(marcador, dict) else None
    if not isinstance(e, dict) or not valido(str(e.get("sid", ""))):
        return None
    ts = _num(e.get("ts"))
    return e if ts > 0 and -60 <= agora - ts <= max_s else None      # 60s de folga de relogio


def _num(v) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def ler_em_voo(path: Path | None = None) -> dict:
    return _json(path or EM_VOO)


def tirar_em_voo(key: str, path: Path | None = None) -> None:
    """No PC: larga a entrada de `key` (espera estourou). O Mac reescreve o arquivo inteiro de todo jeito."""
    p = path or EM_VOO
    d = _json(p)
    if d.pop(key, None) is not None:
        _gravar_json(p, d)


def contar_turno(cont: dict[str, int], key: str) -> None:
    """Um turno do Mac entrou em `key` (antes de esperar o lock: o enfileirado tambem conta)."""
    cont[key] = cont.get(key, 0) + 1


def soltar_turno(cont: dict[str, int], key: str) -> bool:
    """Um turno do Mac saiu de `key`. True so quando foi o ultimo (nenhum segurando nem na fila):
    so ai a copia do Mac esta quieta e o marcador pode cair."""
    n = cont.get(key, 0) - 1
    if n > 0:
        cont[key] = n
        return False
    cont.pop(key, None)
    return True


def apos_escrita_marcador(ok: bool, falhas: int, max_tentativas: int) -> tuple[str, int]:
    """Decide o que fazer com a chave depois de reescrever o marcador no PC. ("remover", n): gravou,
    tira da lista. ("tentar", n): falhou, mantem e tenta de novo. ("largar", n): estourou o teto."""
    if ok:
        return "remover", falhas
    falhas += 1
    return ("tentar" if falhas < max_tentativas else "largar"), falhas


# ---- candidatas do espelho: o topics.json do proprio PC, nao as notas (que chegam em ate 5 min) ----

def ler_topicos_pc(texto: str) -> tuple[str, list[tuple[str, str, str]]] | None:
    """Saida do ssh ("HOME=<home do PC>" e depois o topics.json) -> (home_pc, [(key, sid, cwd_pc)])
    dos topicos com sessao iniciada. None se nao deu para ler."""
    home, resto = "", []
    for linha in texto.splitlines():
        if not home and linha.startswith("HOME="):
            home = linha[5:].strip()
        elif home:
            resto.append(linha)
    try:
        raw = json.loads("\n".join(resto))
    except json.JSONDecodeError:
        return None
    if not home or not isinstance(raw, dict):
        return None
    out = []
    for key, t in raw.items():
        if isinstance(t, dict) and t.get("started") is True and valido(t.get("session_id", "")):
            out.append((key, t["session_id"], str(t.get("cwd") or "")))
    return home, out


def cwd_espelho(cwd_pc: str, home_pc: str, home_mac: str, existe, cwd_store: str, padrao: str) -> str:
    """cwd do PC -> cwd do Mac: o que fica sob o HOME do PC vai para o mesmo lugar sob o HOME do
    Mac (como o "~" da nota). Nao existe aqui? o cwd do store do Mac; senao o padrao."""
    if cwd_pc == home_pc or cwd_pc.startswith(home_pc.rstrip("/") + "/"):
        cand = home_mac + cwd_pc[len(home_pc.rstrip("/")):]
    else:
        cand = cwd_pc
    if cand and existe(cand):
        return cand
    return cwd_store if cwd_store and existe(cwd_store) else padrao


def topicos_no_pc() -> tuple[str, list[tuple[str, str, str]]] | None:
    """Le o topics.json do PC por ssh (script pelo stdin). None = ssh falhou ou nao leu."""
    argv = hosting.pc_argv()
    if argv is None:
        return None
    script = f'echo "HOME=$HOME"\ncat "{hosting.DIR_REMOTO}/topics.json" 2>/dev/null\n'
    try:
        r = subprocess.run(argv, input=script.encode(), capture_output=True, timeout=20)
    except (subprocess.TimeoutExpired, OSError):
        return None
    if r.returncode != 0:
        return None
    return ler_topicos_pc(r.stdout.decode("utf-8", "replace"))


# ---- decisoes puras do turno (sem telegram, testaveis) ----

def decidir_prompt(segue: bool, motivo: str | None, nota: str, started: bool,
                   tem_historia: bool, outro_host: str | None, host: str) -> str:
    """Qual prompt o turno usa: "segue" (so a mensagem, a sessao tem o contexto), "continuacao"
    (sessao nova mas o topico tem historia), "retorno" (outro host respondeu por ultimo) ou "puro".
    Reset automatico apaga a sessao: o `segue` calculado antes dele nao vale mais.
    `segue` com o Log terminando no outro host tambem vira "retorno" (a sessao adotada e mantida)."""
    if motivo:
        segue = False
    if segue:
        # a sessao esta em dia, mas se o outro host respondeu por ultimo no Log (linha mais nova
        # que qualquer turno deste host) a nota mudou sem este host saber: relê a nota
        if nota and outro_host and outro_host != host:
            return "retorno"
        return "segue"
    if nota and not started:
        return "continuacao" if tem_historia else "puro"
    if nota and outro_host and outro_host != host:
        return "retorno"
    return "puro"


def avisar_fila(lk) -> bool:
    """Avisar "entra na fila" so se o turno anterior ainda segura o lock. Ler ANTES de qualquer
    coisa pegar o lock (o alinhar_sessao pega), senao fica sempre False."""
    return lk.locked()
