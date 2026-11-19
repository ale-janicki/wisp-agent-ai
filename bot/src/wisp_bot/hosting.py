from __future__ import annotations
import asyncio, ipaddress, json, logging, os, platform, re, shlex, shutil, signal, socket, time
from pathlib import Path

from . import config, polling
from .config import CURRENT as _CFG

log = logging.getLogger("wisp.hosting")

HOME = Path.home()
DIR = _CFG.state_dir
MODO = _CFG.hosting
PAR = _CFG.pair or {}
STATE = DIR / "host-state.json"
YIELDED = DIR / "peer-yielded"
CLAIM = DIR / "reader-claim.json"
MAC_VISTO = DIR / "mac-seen.json"
CLAIM_PENDENTE = DIR / "claim-pendente.json"
PROTO = 2


def detectar_host() -> str:
    env = os.environ.get("WISP_HOST")
    if env:
        return env
    return "pc" if platform.system() == "Linux" else "mac"


HOST = detectar_host()
GRACE_S = float(os.environ.get("WISP_GRACE_S", "25"))
BATIDA_S = 5.0
CHECK_STANDBY_S = float(os.environ.get("WISP_CHECK_S", "15"))
OFF_RECHECK_S = float(os.environ.get("WISP_OFF_RECHECK_S", "6"))
FECHOU_SONDA1_S = float(os.environ.get("WISP_FECHOU_SONDA1_S", "1.5"))
FECHOU_SONDA2_S = float(os.environ.get("WISP_FECHOU_SONDA2_S", "3"))
FECHOU_SONDA_TIMEOUT_S = float(os.environ.get("WISP_FECHOU_SONDA_TIMEOUT_S", "1.4"))
MUDO_SONDA1_S = float(os.environ.get("WISP_MUDO_SONDA1_S", "0"))
MUDO_SONDA2_S = float(os.environ.get("WISP_MUDO_SONDA2_S", "1.5"))
FECHOU_ATIVA_S = float(os.environ.get("WISP_FECHOU_ATIVA_S", "6"))
CHECK_ACTIVE_S = 5.0
MISSES = int(os.environ.get("WISP_MISSES", "3"))
FRESCO_S = 30
RC_LAN_INALCANCAVEL = 77
RC_PC_WINDOWS = 76
RECONECTA_VIGIA_S = 15.0
OPCOES_VIGIA = ["-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2"]
CONFLITO_BLOQUEIO_S = 300.0
CLAIM_CHECK_S = 1.0
MAC_FRESCO_S = float(os.environ.get("WISP_MAC_FRESCO_S", "90"))
MAC_ESPERA_S = float(os.environ.get("WISP_MAC_ESPERA_S", "60"))
HANDOVER_PC_S = 20.0
ASSENTAR_S = 2.0
LOG_ILEGIVEL_S = 300.0
ALERTA_ILEGIVEL_S = 600.0
CHAVE_NINGUEM_LENDO = "bot-ninguem-lendo"
ALERTA = _CFG.alert_cmd

PC_CFG = Path(os.path.expanduser(str(PAR.get("config") or "~/.config/wisp/pair.conf")))
PC_KEY = Path(os.path.expanduser(str(PAR.get("ssh_key") or "~/.ssh/id_ed25519_wisp_pair")))
PC_TS_NAME = str(PAR.get("pc_name") or "")
PC_USER_LINUX = str(PAR.get("user") or "")


def _dir_remoto() -> str:
    rel = str(PAR.get("state_rel") or "")
    if not rel:
        try:
            rel = str(DIR.relative_to(HOME))
        except ValueError:
            rel = ".local/state/wisp/bot"
    if not config.rel_seguro(rel):
        log.warning("state dir do PC invalido (%r): usando .local/state/wisp/bot", rel)
        return ".local/state/wisp/bot"
    return rel


DIR_REMOTO_REL = _dir_remoto()
DIR_REMOTO = f"$HOME/{DIR_REMOTO_REL}"
TAILSCALE = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"


HOSTS = ("mac", "pc")


def ler_claim(path: Path | None = None) -> dict:
    try:
        d = json.loads((path or CLAIM).read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return d if isinstance(d, dict) and d.get("host") in HOSTS else {}


def gravar_claim(host: str, path: Path | None = None) -> None:
    p = path or CLAIM
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps({"host": host, "ts": int(time.time())}))
    tmp.replace(p)


def trocar_claim(visto: dict, host: str, path: Path | None = None) -> bool:
    if ler_claim(path) != visto:
        return False
    gravar_claim(host, path)
    return True


def restaurar_claim(nosso: str, anterior: str, path: Path | None = None) -> bool:
    p = path or CLAIM
    try:
        atual = p.read_text()
    except OSError:
        return False
    if atual.strip() != nosso.strip():
        return False
    if _claim_valido(anterior):
        tmp = p.with_suffix(".tmp")
        tmp.write_text(anterior.strip())
        tmp.replace(p)
    else:
        p.unlink(missing_ok=True)
    return True


def _claim_valido(texto: str) -> bool:
    try:
        d = json.loads(texto)
    except (json.JSONDecodeError, TypeError):
        return False
    return isinstance(d, dict) and d.get("host") in HOSTS


def script_claim(host: str) -> str:
    if host not in HOSTS:
        raise ValueError(f"host invalido: {host!r}")
    return (f'd="{DIR_REMOTO}"; mkdir -p "$d"\n'
            'tr -d "\\n" 2>/dev/null < "$d/reader-claim.json"; echo\n'
            f'printf \'{{"host": "{host}", "ts": %s}}\' "$(date +%s)" > "$d/reader-claim.tmp"\n'
            'mv "$d/reader-claim.tmp" "$d/reader-claim.json"\n'
            'cat "$d/reader-claim.json"; echo\n'
            'tr -d "\\n" 2>/dev/null < "$d/host-state.json"; echo\n'
            'date +%s\n')


def script_restaurar_claim(nosso: str, anterior: str) -> str:
    volta = (f'printf %s {shlex.quote(anterior.strip())} > "$d/reader-claim.tmp" && '
             'mv "$d/reader-claim.tmp" "$f"' if _claim_valido(anterior) else 'rm -f "$f"')
    return (f'd="{DIR_REMOTO}"; f="$d/reader-claim.json"\n'
            f'if [ "$(cat "$f" 2>/dev/null)" = {shlex.quote(nosso.strip())} ]; then {volta}; echo RESTAURADO; fi\n')


def gravar_claim_pendente(path: Path | None = None) -> None:
    p = path or CLAIM_PENDENTE
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps({"ts": int(time.time())}))
    tmp.replace(p)


def apagar_claim_pendente(path: Path | None = None) -> None:
    (path or CLAIM_PENDENTE).unlink(missing_ok=True)


def idade_claim_pendente(path: Path | None = None) -> int | None:
    try:
        ts = int(json.loads((path or CLAIM_PENDENTE).read_text())["ts"])
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError):
        return None
    return max(0, int(time.time()) - ts)


def script_entregar_claim(idade: int) -> str:
    idade = max(0, int(idade))
    return (f'd="{DIR_REMOTO}"; mkdir -p "$d"\n'
            f'limite=$(( $(date +%s) - {idade} ))\n'
            'atual=$(sed -n \'s/.*"ts": *\\([0-9][0-9]*\\).*/\\1/p\' "$d/reader-claim.json" 2>/dev/null)\n'
            'if [ -z "$atual" ] || [ "$atual" -lt "$limite" ]; then\n'
            '  printf \'{"host": "mac", "ts": %s}\' "$limite" > "$d/reader-claim.tmp" && '
            'mv "$d/reader-claim.tmp" "$d/reader-claim.json"\n'
            'fi\n')


def gravar_estado(estado: str, extra: dict | None = None) -> None:
    DIR.mkdir(parents=True, exist_ok=True)
    dados = {"host": HOST, "state": estado, "ts": int(time.time()), "pid": os.getpid(), "proto": PROTO,
             **(extra or {})}
    claim = ler_claim() if HOST == "pc" else {}
    if claim:
        dados["claim"] = claim
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(dados))
    tmp.replace(STATE)


def ler_mac_visto(path: Path | None = None) -> tuple[float | None, str | None]:
    p = path or MAC_VISTO
    try:
        mtime = p.stat().st_mtime
        d = json.loads(p.read_text())
    except OSError:
        return None, None
    except json.JSONDecodeError:
        return mtime, None
    return mtime, d.get("state") if isinstance(d, dict) else None


def ler_estado_local() -> dict:
    try:
        return json.loads(STATE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def _pc_cfg() -> dict:
    cfg = {}
    try:
        for linha in PC_CFG.read_text().splitlines():
            k, sep, v = linha.partition("=")
            if sep and k.strip() and not k.strip().startswith("#"):
                try:
                    partes = shlex.split(v, comments=True)
                except ValueError:
                    partes = []
                cfg[k.strip()] = partes[0] if partes else ""
    except OSError:
        pass
    return cfg


async def _sh_err(*cmd: str, stdin: bytes | None = None, timeout: float = 10) -> tuple[int, str, str]:
    p = None
    try:
        p = await asyncio.create_subprocess_exec(
            *cmd, stdin=asyncio.subprocess.PIPE if stdin is not None else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, start_new_session=True)
        out, err = await asyncio.wait_for(p.communicate(stdin), timeout=timeout)
        return p.returncode or 0, (out or b"").decode("utf-8", "replace"), (err or b"").decode("utf-8", "replace")
    except (FileNotFoundError, asyncio.TimeoutError):
        if p is not None and p.returncode is None:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                p.kill()
            await p.wait()
        return 124, "", ""


async def _sh(*cmd: str, stdin: bytes | None = None, timeout: float = 10) -> tuple[int, str]:
    rc, out, _ = await _sh_err(*cmd, stdin=stdin, timeout=timeout)
    return rc, out


async def rodar_alerta(*args: str) -> bool:
    if not ALERTA:
        return False
    try:
        p = await asyncio.create_subprocess_exec(*ALERTA, *args, stdin=asyncio.subprocess.DEVNULL,
                                                 stdout=asyncio.subprocess.DEVNULL,
                                                 stderr=asyncio.subprocess.DEVNULL)
        try:
            await asyncio.wait_for(p.wait(), timeout=60)
        except asyncio.TimeoutError:
            p.kill()
            return False
        return True
    except Exception:
        return False


def pc_argv(remoto: str = "bash -s", windows: bool = False, extra: list[str] | None = None) -> list[str] | None:
    if MODO != "pair":
        return None
    cfg = _pc_cfg()
    host = cfg.get("PC_HOST") or cfg.get("PC_LAN_IP")
    user = cfg.get("PC_USER") if windows else (cfg.get("PC_USER_LINUX") or PC_USER_LINUX)
    if not host or not user:
        return None
    cmd = ["ssh", *(extra or []), "-o", "ConnectTimeout=5", "-o", "BatchMode=yes",
           "-o", "StrictHostKeyChecking=accept-new",
           "-o", f"HostKeyAlias={'pc-windows' if windows else 'pc-linux'}"]
    if PC_KEY.exists():
        cmd += ["-i", str(PC_KEY), "-o", "IdentitiesOnly=yes"]
    return cmd + [f"{user}@{host}", remoto]


def ssh_host_inalcancavel(stderr: str) -> bool:
    return "Host is down" in stderr or "No route to host" in stderr


def mesma_lan(ip_local: str | None, ip_pc: str | None) -> bool:
    try:
        a, b = ipaddress.IPv4Address(ip_local), ipaddress.IPv4Address(ip_pc)
    except (ipaddress.AddressValueError, ValueError):
        return False
    return ipaddress.IPv4Network(f"{b}/24", strict=False) == ipaddress.IPv4Network(f"{a}/24", strict=False)


def _ip_local_para(ip_pc: str) -> str | None:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect((ip_pc, 22))
            return s.getsockname()[0]
    except OSError:
        return None


def mac_na_lan_do_pc() -> bool:
    cfg = _pc_cfg()
    ip_pc = cfg.get("PC_HOST") or cfg.get("PC_LAN_IP")
    if not ip_pc or not mesma_lan(ip_pc, ip_pc):
        return False
    return mesma_lan(_ip_local_para(ip_pc), ip_pc)


async def _pc_ssh(script: str) -> tuple[int, str]:
    cmd = pc_argv()
    if cmd is None:
        return 2, ""
    rc, out, err = await _sh_err(*cmd, stdin=script.encode(), timeout=12)
    if rc not in (0, 2) and ssh_host_inalcancavel(err):
        return RC_LAN_INALCANCAVEL, out
    return rc, out


async def _pc_windows_no_ar() -> bool:
    cmd = pc_argv("echo ok", windows=True)
    if cmd is None:
        return False
    rc, out = await _sh(*cmd, timeout=12)
    return rc == 0 and "ok" in out


def node_offline_no_status(saida: str, nome: str) -> bool:
    try:
        st = json.loads(saida)
    except json.JSONDecodeError:
        return False
    if not isinstance(st, dict) or st.get("BackendState") != "Running":
        return False
    for no in (st.get("Peer") or {}).values():
        if isinstance(no, dict) and no.get("HostName") == nome:
            return no.get("Online") is False
    return False


async def _pc_offline_no_tailscale() -> bool:
    exe = TAILSCALE if os.path.exists(TAILSCALE) else shutil.which("tailscale")
    if not exe:
        return False
    nome = _pc_cfg().get("PC_TS_NAME") or PC_TS_NAME
    if not nome:
        return False
    rc, out = await _sh(exe, "status", "--json", timeout=5)
    return rc == 0 and node_offline_no_status(out, nome)


def claim_do_estado(st: dict) -> str | None:
    c = st.get("claim") if isinstance(st, dict) else None
    return c.get("host") if isinstance(c, dict) and c.get("host") in HOSTS else None


def interpretar_estado_pc(rc: int, out: str) -> str | None:
    if rc == RC_PC_WINDOWS:
        return "down"
    if rc != 0:
        return None
    linhas = [l for l in out.strip().splitlines() if l.strip()]
    if len(linhas) == 1 and linhas[0].isdigit():
        return "down"
    if len(linhas) < 2:
        return None
    try:
        st, agora_pc = json.loads(linhas[0]), int(linhas[-1])
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(st, dict):
        return None
    if st.get("state") == "off":
        return "off"
    if agora_pc - int(st.get("ts", 0)) > FRESCO_S:
        return "down"
    if st.get("state") == "standby" and claim_do_estado(st) == "mac":
        return "cedeu"
    return st.get("state") if st.get("state") in ("active", "grace") else "down"


def claim_lido(rc: int, out: str) -> str | None:
    linhas = [l for l in out.strip().splitlines() if l.strip()] if rc == 0 else []
    if len(linhas) < 2:
        return None
    try:
        st, agora_pc = json.loads(linhas[0]), int(linhas[-1])
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(st, dict) or st.get("state") == "off" or agora_pc - int(st.get("ts", 0)) > FRESCO_S:
        return None
    return claim_do_estado(st) or "none"


def script_estado_pc(mac: str | None = None, claim_idade: int | None = None) -> str:
    visto = ""
    if mac in ("active", "standby", "bloqueado"):
        visto = (f'd="{DIR_REMOTO}"; mkdir -p "$d"\n'
                 f'echo \'{{"state": "{mac}"}}\' > "$d/mac-seen.tmp" && mv "$d/mac-seen.tmp" "$d/mac-seen.json"\n')
        if claim_idade is not None:
            visto += script_entregar_claim(claim_idade)
    return visto + f'cat "{DIR_REMOTO}/host-state.json" 2>/dev/null; echo; date +%s'


async def estado_do_pc(mac: str | None = None, claim_idade: int | None = None, lido: dict | None = None) -> str | None:
    if await _pc_offline_no_tailscale():
        return "offline"
    rc, out = await _pc_ssh(script_estado_pc(mac, claim_idade))
    if lido is not None:
        lido["claim"] = claim_lido(rc, out)
        lido["entregue"] = rc == 0 and claim_idade is not None and mac in ("active", "standby", "bloqueado")
    if rc not in (0, 2):
        if await _pc_windows_no_ar():
            rc = RC_PC_WINDOWS
        elif rc == RC_LAN_INALCANCAVEL and mac_na_lan_do_pc():
            return "down"
    return interpretar_estado_pc(rc, out)


def linha_diz_off(linha: str) -> bool:
    try:
        st = json.loads(linha)
    except json.JSONDecodeError:
        return False
    return isinstance(st, dict) and st.get("state") == "off"


def linha_diz_cedeu(linha: str) -> bool:
    try:
        st = json.loads(linha)
    except json.JSONDecodeError:
        return False
    return isinstance(st, dict) and st.get("state") == "standby" and claim_do_estado(st) == "mac"


SCRIPT_VIGIA = (f'f="{DIR_REMOTO}/host-state.json"\n'
                'while :; do\n'
                '  if [ -r "$f" ]; then tr -d "\\n" < "$f"; echo; else echo "{}"; fi\n'
                '  sleep 1\n'
                'done\n')


_FECHOU_RE = re.compile(r"^Connection to \S+ closed by remote host\.?\s*$", re.MULTILINE)


def pc_fechou_a_sessao(stderr: str) -> bool:
    return _FECHOU_RE.search(stderr) is not None


_CALOU_RE = re.compile(r"^Timeout, server \S+ not responding", re.MULTILINE)


def pc_calou(stderr: str) -> bool:
    return _CALOU_RE.search(stderr) is not None


def gateway_padrao(saida_route: str) -> str:
    m = re.search(r"^\s*gateway:\s*(\S+)", saida_route, re.M)
    return m[1] if m else ""


async def roteador_responde() -> bool:
    rc, saida = await _sh("route", "-n", "get", "default", timeout=3)
    gw = gateway_padrao(saida) if rc == 0 else ""
    try:
        ipaddress.IPv4Address(gw)
    except ValueError:
        return False
    rc, _ = await _sh("ping", "-c", "1", "-t", "1", gw, timeout=2)
    return rc == 0


async def pc_responde() -> bool:
    cmd = pc_argv("true")
    if cmd is None:
        return True
    rc, _, _ = await _sh_err(*cmd, timeout=FECHOU_SONDA_TIMEOUT_S)
    return rc == 0


def decidir_mac(pc: str | None, faltas: int, ativo: bool, bloqueado: bool = False) -> tuple[str, int]:
    if pc in ("active", "grace"):
        return "ceder", 0
    if pc is None:
        return "manter", 0
    faltas += 1
    if not ativo and not bloqueado and (pc in ("cedeu", "offline", "fechou", "mudo") or (pc == "off" and faltas >= 2) or faltas >= MISSES):
        return "ativar", faltas
    return "manter", faltas


def decidir_pc(claim: str | None, ativo: bool, ocupado: bool, mac_idade: float, mac_ativo: bool,
               mac_parado_s: float, mac_bloqueado: bool = False) -> str:
    if claim != "mac":
        return "manter" if ativo else "ler"
    if mac_idade > MAC_FRESCO_S:
        return "tomar"
    if mac_bloqueado:
        return "manter" if ativo else "retomar"
    if ativo:
        return "esperar" if ocupado else "soltar"
    if not mac_ativo and mac_parado_s > MAC_ESPERA_S:
        return "retomar"
    return "manter"


async def ceder_ao_pc() -> None:
    await _pc_ssh(f'touch "{DIR_REMOTO}/peer-yielded"')


def script_em_voo(dados: dict, nome: str = "em-voo-mac.json") -> str:
    corpo = json.dumps(dados, sort_keys=True)
    return (f'd="{DIR_REMOTO}"; mkdir -p "$d"\n'
            f'cat > "$d/{nome}.tmp" <<\'WISP_EMVOO_EOF\'\n{corpo}\nWISP_EMVOO_EOF\n'
            f'mv "$d/{nome}.tmp" "$d/{nome}"\n')


async def gravar_em_voo_pc(dados: dict, nome: str = "em-voo-mac.json") -> bool:
    rc, _ = await _pc_ssh(script_em_voo(dados, nome))
    return rc == 0


class Hosting:

    def __init__(self, app, on_ativar, on_desativar, antes_de_ceder=None, alerta=rodar_alerta,
                 ocupado=None, antes_de_soltar=None):
        self.app = app
        self.alerta = alerta
        self.antes_de_ceder = antes_de_ceder
        self.ocupado = ocupado or (lambda: False)
        self.antes_de_soltar = antes_de_soltar
        self._precisa_grace = True
        self._mac_parado_desde: float | None = None
        self._esperando_turno = False
        self._tentar_em = 0.0
        self.claim_pc: str | None = None
        self.on_ativar, self.on_desativar = on_ativar, on_desativar
        self.estado = "standby"
        self.desde = time.time()
        self.pc_estado: str | None = None
        self.falha_rede_inicio: float | None = None
        self.falha_rede_ts: float | None = None
        self.ultima_queda_rede: tuple[float, float] | None = None
        self.bloqueado_ate = 0.0
        self.ilegivel_desde: float | None = None
        self.ultimo_log_ilegivel = 0.0
        self._cessao: asyncio.Task | None = None
        self.alerta_aberto = False
        self._soltas: set[asyncio.Task] = set()
        self._off = asyncio.Event()
        self._mudanca = asyncio.Event()
        self._sinal: tuple[float, str] | None = None
        self._sem_leitura = False
        self._soltando = False
        self._vigia_ligada = False
        self._erro_polling = polling.ErroPolling(self.conflito)

    @property
    def ativo(self) -> bool:
        return self.estado == "active"

    async def ativar(self, motivo: str) -> None:
        if self.ativo:
            return
        log.info("ativando em %s: %s", HOST, motivo)
        try:
            await self.app.updater.start_polling(drop_pending_updates=False, timeout=polling.POLL_TIMEOUT_S,
                                                 error_callback=self._erro_polling)
        except Exception as e:
            log.warning("start_polling falhou: %s", e)
            if polling.erro_de_rede(e):
                self.falha_rede_ts = time.time()
                if self.falha_rede_inicio is None:
                    self.falha_rede_inicio = self.falha_rede_ts
            return
        if self.falha_rede_inicio is not None and self.falha_rede_ts is not None:
            self.ultima_queda_rede = (self.falha_rede_inicio, self.falha_rede_ts)
        self.falha_rede_inicio = self.falha_rede_ts = None
        self.estado, self.desde = "active", time.time()
        self._mudanca.set()
        self._publicar("active")
        try:
            await self.on_ativar(motivo)
        except Exception as e:
            log.warning("on_ativar falhou: %s", e)

    async def desativar(self, motivo: str) -> None:
        if not self.ativo or self._soltando:
            return
        self._soltando = True
        try:
            log.info("soltando em %s: %s", HOST, motivo)
            try:
                await self.on_desativar(motivo)
            except Exception as e:
                log.warning("on_desativar falhou: %s", e)
            await self.app.updater.stop()
            self.estado, self.desde = "standby", time.time()
            self._mudanca.set()
            self._publicar("standby")
        finally:
            self._soltando = False

    def _publicar(self, estado: str) -> None:
        extra = {}
        if HOST != "pc":
            if time.monotonic() < self.bloqueado_ate:
                extra["bloqueado_ate"] = int(time.time() + (self.bloqueado_ate - time.monotonic()))
            if self.claim_pc:
                extra["claim_pc"] = self.claim_pc
        gravar_estado(estado, extra)

    async def _religar(self) -> bool:
        try:
            await self.app.updater.start_polling(drop_pending_updates=False, timeout=polling.POLL_TIMEOUT_S,
                                                 error_callback=self._erro_polling)
            return True
        except Exception as e:
            log.warning("religar a leitura falhou: %s", e)
            return False

    async def _assentar(self) -> None:
        fila = getattr(self.app, "update_queue", None)
        fim = time.monotonic() + ASSENTAR_S
        while fila is not None and not fila.empty() and time.monotonic() < fim:
            await asyncio.sleep(0.05)
        for _ in range(3):
            await asyncio.sleep(0)

    def conflito(self) -> None:
        if HOST == "pc" or not self.ativo or (self._cessao and not self._cessao.done()):
            return
        self.bloqueado_ate = time.monotonic() + CONFLITO_BLOQUEIO_S
        self._cessao = asyncio.get_running_loop().create_task(self.desativar("409 Conflict: outro leitor"))
        self._cessao.add_done_callback(self._cessao_terminou)

    @staticmethod
    def _cessao_terminou(t: asyncio.Task) -> None:
        if not t.cancelled() and t.exception():
            log.error("cessao por 409 falhou: %r", t.exception())

    def _soltar(self, *args: str) -> None:
        t = asyncio.get_running_loop().create_task(self.alerta(*args))
        self._soltas.add(t)
        t.add_done_callback(self._soltas.discard)

    def _avisar_ilegivel(self, pc: str | None, agora: float | None = None) -> None:
        agora = time.monotonic() if agora is None else agora
        if pc is not None:
            self.ilegivel_desde = None
            if self.alerta_aberto:
                self.alerta_aberto = False
                self._soltar("resolve", CHAVE_NINGUEM_LENDO)
            return
        if self.ilegivel_desde is None:
            self.ilegivel_desde = agora
        parado = agora - self.ilegivel_desde
        if agora - self.ultimo_log_ilegivel >= LOG_ILEGIVEL_S:
            self.ultimo_log_ilegivel = agora
            log.warning("estado do PC ilegivel ha %ds; mantendo %s (ilegivel nao ativa a leitura)",
                        int(parado), self.estado)
        if parado > ALERTA_ILEGIVEL_S and not self.alerta_aberto and not self.ativo:
            self.alerta_aberto = True
            self._soltar("add", "--nivel", "red", "--chave", CHAVE_NINGUEM_LENDO, "--frente", "bot",
                         f"Ninguem esta lendo o Telegram: o Mac nao consegue ler o estado do PC ha {int(parado // 60)} min "
                         "e o Tailscale nao diz que o PC caiu. Confira o bot do PC.")

    async def rodar(self) -> None:
        if MODO != "pair":
            await self._rodar_solo()
            return
        await (self._rodar_pc() if HOST == "pc" else self._rodar_mac())

    async def _rodar_solo(self) -> None:
        while True:
            if not self.ativo and time.monotonic() >= self.bloqueado_ate:
                await self.ativar("solo")
            self._publicar(self.estado)
            await asyncio.sleep(BATIDA_S)

    async def _rodar_pc(self) -> None:
        YIELDED.unlink(missing_ok=True)
        boot = time.time()
        while True:
            await self._passo_pc(boot)
            await asyncio.sleep(CLAIM_CHECK_S)

    async def _passo_pc(self, boot: float) -> None:
        if self._sem_leitura:
            self._sem_leitura = not await self._religar()
            gravar_estado("active" if self.ativo else "standby")
            return
        visto = ler_claim()
        claim = visto.get("host")
        mtime, mac_st = ler_mac_visto()
        agora = time.time()
        mac_idade = agora - max(boot, mtime or 0.0)
        mac_ativo = mac_st == "active" and mac_idade <= MAC_FRESCO_S
        mac_bloqueado = mac_st == "bloqueado" and mac_idade <= MAC_FRESCO_S
        if claim != "mac" or mac_ativo or self.ativo:
            self._mac_parado_desde = None
        elif self._mac_parado_desde is None:
            self._mac_parado_desde = agora
        parado = agora - self._mac_parado_desde if self._mac_parado_desde is not None else 0.0
        acao = decidir_pc(claim, self.ativo, self.ocupado(), mac_idade, mac_ativo, parado, mac_bloqueado)
        if acao != "esperar":
            self._esperando_turno = False
        if acao == "ler":
            await self._ler_pc()
        elif acao == "tomar":
            if trocar_claim(visto, "pc"):
                log.info("claim do Mac, mas o Mac nao checa ha %ds: o claim volta ao PC", int(mac_idade))
                if not self.ativo:
                    self._precisa_grace = False
                    await self.ativar("o Mac sumiu (claim dele, sem checar)")
        elif acao == "retomar":
            if trocar_claim(visto, "pc"):
                log.info("claim do Mac, mas o Mac %s: o claim volta ao PC",
                         "esta bloqueado (409)" if mac_bloqueado else f"nao le ha {int(parado)}s")
                self._mac_parado_desde = None
                await self._ler_pc()
        elif acao == "esperar" and not self._esperando_turno:
            self._esperando_turno = True
            log.info("claim do Mac: espero o turno em curso acabar para soltar")
        elif acao == "soltar":
            await self._soltar_para_o_mac()
        gravar_estado("active" if self.ativo else "grace" if self.estado == "grace" else "standby")

    async def _ler_pc(self) -> None:
        if self._precisa_grace:
            YIELDED.unlink(missing_ok=True)
            self.estado = "grace"
            fim = time.time() + GRACE_S
            while time.time() < fim and not YIELDED.exists() and ler_claim().get("host") != "mac":
                gravar_estado("grace")
                await asyncio.sleep(1)
            cedeu = YIELDED.exists()
            YIELDED.unlink(missing_ok=True)
            self.estado = "standby"
            if ler_claim().get("host") == "mac":
                log.info("grace abortado: o Wisp do Mac pediu a leitura")
                return
            self._precisa_grace = False
            await self.ativar("o Mac cedeu" if cedeu else f"ninguem respondeu em {int(GRACE_S)}s")
            if not self.ativo:
                self.estado = "grace"
            return
        if time.monotonic() < self._tentar_em:
            return
        self._tentar_em = time.monotonic() + BATIDA_S
        await self.ativar("nova tentativa")
        if not self.ativo:
            self.estado = "grace"

    async def _soltar_para_o_mac(self) -> None:
        log.info("claim do Mac: soltando a leitura")
        if self.antes_de_soltar:
            try:
                await asyncio.wait_for(self.antes_de_soltar(), HANDOVER_PC_S + 5)
            except Exception as e:
                log.warning("antes_de_soltar falhou: %r", e)
        if ler_claim().get("host") != "mac" or self.ocupado() or not self.ativo or self._soltando:
            return
        self._soltando = True
        try:
            await self.app.updater.stop()
            await self._assentar()
            if self.ocupado() or ler_claim().get("host") != "mac":
                log.info("chegou trabalho (ou o claim mudou) enquanto soltava: sigo lendo")
                if not await self._religar():
                    log.warning("nao consegui religar a leitura: sigo ativo e tento de novo no proximo passo")
                    self._sem_leitura = True
                return
            log.info("soltando em %s: o Wisp do Mac pediu a leitura", HOST)
            try:
                await self.on_desativar("o Wisp do Mac pediu a leitura")
            except Exception as e:
                log.warning("on_desativar falhou: %s", e)
            self.estado, self.desde = "standby", time.time()
            self._mudanca.set()
            self._publicar("standby")
            self._precisa_grace = True
        finally:
            self._soltando = False

    async def _esperar_mudanca_para_standby(self) -> None:
        while self.ativo:
            self._mudanca.clear()
            await self._mudanca.wait()

    async def _esperar_ativo(self) -> None:
        while not self.ativo:
            self._mudanca.clear()
            await self._mudanca.wait()

    async def _ler_vigia(self, p) -> int:
        viu_off = False
        linhas = 0
        while True:
            bruto = await p.stdout.readline()
            if not bruto:
                return linhas
            linhas += 1
            if not self._vigia_ligada:
                self._vigia_ligada = True
                log.info("vigia do PC conectada")
            texto = bruto.decode("utf-8", "replace")
            off = linha_diz_off(texto) or linha_diz_cedeu(texto)
            if off and not viu_off:
                log.info("PC avisou que %s: decidindo agora",
                         "desligou (off)" if linha_diz_off(texto) else "soltou para o Mac (claim)")
                self._off.set()
            viu_off = off

    async def _sessao_vigia(self) -> None:
        argv = pc_argv(extra=OPCOES_VIGIA)
        if argv is None:
            return
        p = await asyncio.create_subprocess_exec(*argv, stdin=asyncio.subprocess.PIPE,
                                                 stdout=asyncio.subprocess.PIPE,
                                                 stderr=asyncio.subprocess.PIPE)
        tarefas: list[asyncio.Future] = []
        erro = bytearray()
        try:
            p.stdin.write(SCRIPT_VIGIA.encode())
            await p.stdin.drain()
            p.stdin.close()
            leitura = asyncio.ensure_future(self._ler_vigia(p))
            tarefas = [leitura, asyncio.ensure_future(self._esperar_ativo()),
                       asyncio.ensure_future(self._drenar_stderr(p, erro))]
            await asyncio.wait(tarefas[:2], return_when=asyncio.FIRST_COMPLETED)
            if leitura.done() and not leitura.cancelled() and not leitura.exception() \
                    and leitura.result() > 0 and not self.ativo:
                try:
                    await asyncio.wait_for(asyncio.shield(tarefas[2]), timeout=2)
                except asyncio.TimeoutError:
                    pass
                texto = bytes(erro).decode("utf-8", "replace")
                if pc_fechou_a_sessao(texto):
                    log.info("PC fechou a sessao do vigia: decidindo agora")
                    self._sinal = (time.monotonic(), "fechou")
                    self._off.set()
                elif pc_calou(texto) and mac_na_lan_do_pc():
                    log.info("PC parou de responder ao vigia: decidindo agora")
                    self._sinal = (time.monotonic(), "mudo")
                    self._off.set()
        finally:
            for t in tarefas:
                t.cancel()
            if tarefas:
                await asyncio.gather(*tarefas, return_exceptions=True)
            if p.returncode is None:
                p.kill()
            self._vigia_ligada = False
            try:
                await asyncio.wait_for(p.wait(), timeout=5)
            except Exception:
                pass

    @staticmethod
    async def _drenar_stderr(p, destino: bytearray, teto: int = 8192) -> None:
        while True:
            pedaco = await p.stderr.read(4096)
            if not pedaco:
                return
            if len(destino) < teto:
                destino += pedaco[:teto - len(destino)]

    async def _vigiar_pc(self) -> None:
        if HOST == "pc":
            return
        while True:
            try:
                if self.ativo:
                    await self._esperar_mudanca_para_standby()
                else:
                    await self._sessao_vigia()
                    await asyncio.sleep(RECONECTA_VIGIA_S)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.debug("vigia do PC falhou: %r", e)
                await asyncio.sleep(RECONECTA_VIGIA_S)

    async def _esperar_ciclo(self, segundos: float) -> None:
        if not self._vigia_ligada:
            await asyncio.sleep(segundos)
            return
        try:
            await asyncio.wait_for(self._off.wait(), timeout=segundos)
        except asyncio.TimeoutError:
            pass

    async def _rodar_mac(self) -> None:
        gravar_estado("standby")
        vigia = asyncio.get_running_loop().create_task(self._vigiar_pc())
        try:
            await self._laco_mac()
        finally:
            vigia.cancel()
            await asyncio.gather(vigia, return_exceptions=True)

    @staticmethod
    async def _esperar_offset(sinal: float, offset: float) -> None:
        resto = offset - (time.monotonic() - sinal)
        if resto > 0:
            await asyncio.sleep(resto)

    async def _pc_fechou(self, sinal: float) -> str | None:
        for offset in (FECHOU_SONDA1_S, FECHOU_SONDA2_S):
            await self._esperar_offset(sinal, offset)
            if await pc_responde():
                return None
        log.info("PC sem resposta apos fechar a sessao: PC desligando")
        await self._esperar_offset(sinal, FECHOU_ATIVA_S)
        return "fechou"

    async def _pc_mudo(self, sinal: float) -> str | None:
        await self._esperar_offset(sinal, MUDO_SONDA1_S)
        if not await roteador_responde():
            log.info("roteador do Mac nao responde: sinal da vigia descartado")
            return None
        if await pc_responde():
            return None
        await self._esperar_offset(sinal, MUDO_SONDA2_S)
        if await pc_responde():
            return None
        if not (mac_na_lan_do_pc() and await roteador_responde()):
            return None
        log.info("PC sem resposta e roteador ok: PC caiu")
        return "mudo"

    async def _laco_mac(self) -> None:
        faltas = 0
        while True:
            sinal, self._sinal = (self._sinal if not self.ativo else None), None
            self._off.clear()
            pc = None
            lido: dict = {}
            if sinal is not None:
                pc = await (self._pc_fechou(sinal[0]) if sinal[1] == "fechou" else self._pc_mudo(sinal[0]))
            bloqueado = time.monotonic() < self.bloqueado_ate
            if pc is None:
                pendente = idade_claim_pendente()
                pc = await estado_do_pc(mac="bloqueado" if bloqueado and not self.ativo else self.estado,
                                        claim_idade=pendente, lido=lido)
                if pendente is not None and lido.get("entregue"):
                    apagar_claim_pendente()
                    log.info("claim pendente do Wisp entregue ao PC")
            self.pc_estado = pc
            self.claim_pc = lido.get("claim")
            self._avisar_ilegivel(pc)
            acao, faltas = decidir_mac(pc, faltas, self.ativo, bloqueado)
            if acao == "ceder" and pc == "grace" and self.ativo and lido.get("entregue"):
                acao = "manter"
            if acao == "ceder":
                if self.ativo:
                    await self.desativar("o PC voltou")
                if pc == "grace":
                    if self.antes_de_ceder:
                        try:
                            await self.antes_de_ceder()
                        except Exception as e:
                            log.warning("antes_de_ceder falhou: %s", e)
                    await ceder_ao_pc()
            elif acao == "ativar":
                await self.ativar({"cedeu": "o PC soltou (claim do Mac)", "offline": "PC offline no Tailscale",
                                   "off": "PC desligou (off)", "fechou": "PC fechou a conexao",
                                   "mudo": "PC parou de responder"}.get(pc, "PC fora"))
            self._publicar(self.estado)
            if self.ativo:
                espera = CHECK_ACTIVE_S
            else:
                espera = OFF_RECHECK_S if pc == "off" else CHECK_STANDBY_S
            await self._esperar_ciclo(espera)
