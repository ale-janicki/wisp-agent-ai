"""Mac acordado so enquanto ha trabalho; no PC (Linux/WSL) tudo aqui e no-op.

Medido: na bateria o Mac ainda acorda em DarkWake de 5-10s a cada 1-3 min; o bot
le o Telegram nessa janela, abre o claude e o sistema dorme no meio ("went to sleep
mid-response"). Segura-se com `caffeinate -i -s -w <pid do bot>` por chave (topico);
`-s` nao vale na bateria, entao com tampa fechada na bateria nada segura e o turno espera.
"""
from __future__ import annotations
import asyncio, logging, os, subprocess, sys
from typing import Awaitable, Callable

log = logging.getLogger("wisp.vigilia")

MAC = sys.platform == "darwin"
SEGURA_GERAL_S = 1800      # Geral: 30 min esperando ele continuar a conversa
SEGURA_TOPICO_S = 3600     # topico: 1h sem mensagem do usuario, contada a partir do fim do turno
POLL_S = 30

_caf: dict[str, subprocess.Popen] = {}
_timers: dict[str, asyncio.TimerHandle] = {}


_reapers: set[asyncio.Task] = set()


async def _saida(*cmd: str) -> str:
    try:
        p = await asyncio.create_subprocess_exec(*cmd, stdin=asyncio.subprocess.DEVNULL,
                                                 stdout=asyncio.subprocess.PIPE,
                                                 stderr=asyncio.subprocess.DEVNULL)
        try:
            out, _ = await asyncio.wait_for(p.communicate(), timeout=10)
        except BaseException:
            p.kill()
            await p.wait()
            raise
        return out.decode("utf-8", "replace")
    except Exception as e:
        log.warning("%s falhou: %s", cmd[0], e)
        return ""


def parse_acordado(systemstate: str) -> bool:
    """Full wake tem Graphics nas capacidades; DarkWake nao."""
    for linha in systemstate.splitlines():
        if "Current System Capabilities are:" in linha:
            return "Graphics" in linha
    return True                                    # nao entendi a saida: nao forco nada


def parse_tampa_fechada(ioreg: str) -> bool:
    return any('"AppleClamshellState"' in l and l.split("=", 1)[1].strip() == "Yes"
               for l in ioreg.splitlines() if "=" in l)


def parse_na_tomada(ps: str) -> bool:
    return "Now drawing from 'AC Power'" in ps


async def estado() -> dict:
    estado_, ioreg, ps = await asyncio.gather(
        _saida("pmset", "-g", "systemstate"),
        _saida("ioreg", "-r", "-k", "AppleClamshellState", "-d", "4"),
        _saida("pmset", "-g", "ps"))
    return {"acordado": parse_acordado(estado_), "tampa_fechada": parse_tampa_fechada(ioreg),
            "tomada": parse_na_tomada(ps)}


def pode_segurar(est: dict) -> bool:
    """Tampa fechada na bateria: o macOS forca o sono e nada segura."""
    return not (est["tampa_fechada"] and not est["tomada"])


async def acordar() -> None:
    """Declara atividade de usuario: promove DarkWake a full wake. Nao espera os 5s do caffeinate."""
    if not MAC or (await estado())["acordado"]:
        return
    try:
        p = await asyncio.create_subprocess_exec("caffeinate", "-u", "-t", "5",
                                                 stdin=asyncio.subprocess.DEVNULL,
                                                 stdout=asyncio.subprocess.DEVNULL,
                                                 stderr=asyncio.subprocess.DEVNULL)
    except Exception as e:
        log.warning("caffeinate -u falhou: %s", e)
        return
    t = asyncio.create_task(p.wait())              # colhe sem zumbi; o turno segue
    _reapers.add(t)
    t.add_done_callback(_reapers.discard)


def segurar(key: str) -> None:
    """Idempotente; uma nova mensagem cancela a soltura agendada."""
    if not MAC:
        return
    t = _timers.pop(key, None)
    if t:
        t.cancel()
    p = _caf.get(key)
    if p and p.poll() is None:
        return
    try:
        _caf[key] = subprocess.Popen(["caffeinate", "-i", "-s", "-w", str(os.getpid())],
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        log.info("vigilia %s: segurando (pid %d)", key, _caf[key].pid)
    except Exception as e:
        log.warning("vigilia %s: caffeinate nao subiu: %s", key, e)


def soltar(key: str) -> None:
    t = _timers.pop(key, None)
    if t:
        t.cancel()
    p = _caf.pop(key, None)
    if p:
        p.kill()
        try:
            p.wait(timeout=5)                      # colhe, sem zumbi
        except Exception:
            pass
        log.info("vigilia %s: solta", key)


def soltar_todas() -> None:
    for k in list(_caf) + list(_timers):
        soltar(k)


def agendar_soltura(key: str, segundos: float) -> None:
    if not MAC:
        return
    t = _timers.pop(key, None)
    if t:
        t.cancel()
    _timers[key] = asyncio.get_running_loop().call_later(segundos, soltar, key)


async def esperar_poder(aviso: Callable[[], Awaitable[None]]) -> None:
    if not MAC:
        return
    if not pode_segurar(await estado()):
        try:
            await aviso()
        except Exception as e:
            log.warning("aviso de vigilia falhou: %s", e)
        while not pode_segurar(await estado()):
            await asyncio.sleep(POLL_S)
    await acordar()
