"""Canario do proprio processo: detecta que o bot ficou ruim e se reinicia.

Incidente 22/10: o `brew upgrade` apagou o Python em que o bot (standby desde a noite) rodava.
O processo seguiu vivo, mas todo import preguicoso da stdlib (`encodings.idna`) falhava e todo
subprocesso `claude` saia 1 na hora. Ninguem viu por 4h; um processo novo resolveu.

A checagem roda DENTRO do processo (um subprocesso nasce sao e esconde o defeito) e nos dois
hosts, ativo ou standby. Falha confirmada = desligamento limpo (o `parar` do `_viver`), e o
launchd/systemd sobe de novo. Se o processo novo tambem falha, avisa no Geral uma vez.
"""
from __future__ import annotations
import asyncio, json, logging, os, sys, time
from pathlib import Path
from typing import Awaitable, Callable

from .claude_runner import claude_bin
from .hosting import DIR, HOST, _sh

log = logging.getLogger("wisp.saude")

ARQUIVO = DIR / "saude.json"
INTERVALO_S = 600
PRIMEIRA_S = 60
RETRY_S = 30
CLAUDE_TIMEOUT_S = 30
ALERTA_S = 10
REINICIO_INTERPRETE_S = 1800   # mesmo motivo (interprete) so reinicia a cada 30 min
ERRO_INTERPRETE = "interprete"
ERRO_CLAUDE = "claude"

Check = Callable[[], Awaitable[str | None]]   # None = ok, texto = erro


def _registrar() -> dict[str, str]:
    """Caminhos de que o processo depende -> realpath de agora (22/10)."""
    import sysconfig
    caminhos = (os.path.dirname(os.__file__), sys.base_prefix, sysconfig.get_paths()["purelib"])
    return {c: os.path.realpath(c) for c in caminhos}


REGISTRO = _registrar()   # tirado no import, com o interprete ainda inteiro


def verificar_caminhos(registro: dict[str, str]) -> str | None:
    """Sem cache de codec: olha o disco. Sumiu ou o symlink aponta pra outro lugar = interprete trocado."""
    for original, gravado in registro.items():
        if not os.path.exists(original):
            return f"{ERRO_INTERPRETE}: {original} sumiu"
        atual = os.path.realpath(original)
        if atual != gravado:
            return f"{ERRO_INTERPRETE}: {original} agora aponta pra {atual} (era {gravado})"
    return None


async def checar_interprete() -> str | None:
    return verificar_caminhos(REGISTRO)


async def checar_claude() -> str | None:
    rc, out = await _sh(claude_bin(), "--version", timeout=CLAUDE_TIMEOUT_S)
    return None if rc == 0 else f"{ERRO_CLAUDE}: --version saiu {rc}"


CHECKS: tuple[Check, ...] = (checar_interprete, checar_claude)


def ler(arquivo: Path = ARQUIVO) -> dict:
    try:
        return json.loads(arquivo.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def _gravar(dados: dict, arquivo: Path) -> None:
    # disco cheio/permissao nao pode engolir o parar.set() que vem depois (22/10)
    try:
        arquivo.parent.mkdir(parents=True, exist_ok=True)
        tmp = arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados))
        tmp.replace(arquivo)
    except OSError as e:
        log.warning("saude: estado nao gravou: %r", e)


async def _primeiro_erro(checks: tuple[Check, ...]) -> str | None:
    for c in checks:
        erro = await c()
        if erro:
            return erro
    return None


async def checar_com_retry(checks: tuple[Check, ...], retry_s: float = RETRY_S) -> str | None:
    """Falha so conta se repetir: um tropeco passageiro nao reinicia o bot."""
    erro = await _primeiro_erro(checks)
    if erro is None:
        return None
    log.warning("saude: %s; conferindo de novo em %ss", erro, retry_s)
    await asyncio.sleep(retry_s)
    return await _primeiro_erro(checks)


async def _avisar(enviar: Callable[[str], Awaitable[None]], texto: str) -> bool:
    try:
        await asyncio.wait_for(enviar(texto), ALERTA_S)   # rede morta nao segura o reinicio
        return True
    except Exception as e:                      # rede fora e justamente o caso: nunca derruba
        log.warning("saude: alerta nao saiu: %r", e)
        return False


async def decidir(erro: str | None, enviar: Callable[[str], Awaitable[None]],
                  parar: asyncio.Event, arquivo: Path = ARQUIVO) -> None:
    """Aplica o resultado de uma checagem confirmada: zera, ou conta, avisa e pede o desligamento."""
    antes = ler(arquivo)
    agora = int(time.time())
    if erro is None:
        if antes.get("falhas_seguidas") or antes.get("alertado") or antes.get("claude_falhas"):
            # ts_interp fica: o limite de 30 min vale mesmo com passagem no meio
            _gravar({"falhas_seguidas": 0, "alertado": False, "claude_falhas": 0, "ultimo_erro": "",
                     "ts": agora, "ts_interp": antes.get("ts_interp", 0)}, arquivo)
        return
    if erro.startswith(ERRO_INTERPRETE):
        # interprete trocado: so reiniciar resolve, mas nao em loop (22/10)
        desde = agora - int(antes.get("ts_interp", 0))
        dados = {**antes, "ultimo_erro": erro, "ts": agora}
        if desde > REINICIO_INTERPRETE_S:
            dados["ts_interp"] = agora
            log.warning("saude: %s; reiniciando", erro)
            _gravar(dados, arquivo)
            parar.set()
            return
        if not antes.get("alertado") and await _avisar(
                enviar, f"⚠️ bot do {HOST} com interprete trocado, reiniciei ha {desde // 60} min: {erro[:200]}"):
            dados["alertado"] = True
        _gravar(dados, arquivo)
        return
    claude_falhas = int(antes.get("claude_falhas", 0))
    if erro.startswith(ERRO_CLAUDE):
        claude_falhas += 1
        if claude_falhas < 2:                   # claude lento nao mata turno em andamento (22/10)
            log.warning("saude: %s (ciclo %s, ainda nao reinicia)", erro, claude_falhas)
            _gravar({**antes, "claude_falhas": claude_falhas, "ultimo_erro": erro, "ts": agora}, arquivo)
            return
    n = int(antes.get("falhas_seguidas", 0)) + 1
    alertado = bool(antes.get("alertado"))
    log.warning("saude: falha confirmada (%s seguidas): %s", n, erro)
    if n >= 2 and not alertado:
        alertado = await _avisar(enviar, f"⚠️ bot do {HOST} com defeito mesmo depois de reiniciar: {erro[:200]}")
    dados = {**antes, "falhas_seguidas": n, "claude_falhas": claude_falhas, "ultimo_erro": erro, "ts": agora}
    dados["alertado"] = alertado
    _gravar(dados, arquivo)
    if not alertado:                            # avisado: reiniciar de novo nao ajuda, fica de pe e segue olhando
        parar.set()


async def vigiar(enviar: Callable[[str], Awaitable[None]], parar: asyncio.Event,
                 checks: tuple[Check, ...] = CHECKS, arquivo: Path = ARQUIVO) -> None:
    await asyncio.sleep(PRIMEIRA_S)
    while not parar.is_set():
        try:
            await decidir(await checar_com_retry(checks), enviar, parar, arquivo)
        except Exception as e:                  # o canario nunca pode ser quem derruba o bot
            log.warning("saude: checagem quebrou: %r", e)
        await asyncio.sleep(INTERVALO_S)
