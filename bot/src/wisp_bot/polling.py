"""Saude da leitura do Telegram: watchdog do getUpdates, timeouts finitos e log de erro sem ruido."""
from __future__ import annotations
import logging, os, threading, time
from typing import Callable

import httpx
from telegram.error import BadRequest, Conflict, NetworkError, TelegramError, TimedOut
from telegram.ext import ExtBot
from telegram.request import HTTPXRequest

log = logging.getLogger("wisp.polling")

WATCHDOG_S = float(os.environ.get("WISP_WATCHDOG_S", "300"))
WATCHDOG_CHECK_S = 15.0
WATCHDOG_EXIT = 70
POLL_TIMEOUT_S = 10
POLL_READ_TIMEOUT_S = 15.0
REDE_LOG_S = 300.0


def erro_de_rede(e: BaseException) -> bool:
    """So falha de conectividade conta como "sem internet"; token invalido ou Forbidden nao."""
    return isinstance(e, (httpx.ConnectError, httpx.TimeoutException, NetworkError, TimedOut, OSError))


class PollingWatchdog:
    """Marca o ultimo getUpdates concluido; vence se o host le e nenhum conclui em `limite_s`."""

    def __init__(self, limite_s: float = WATCHDOG_S, relogio: Callable[[], float] = time.monotonic):
        self.limite_s, self.relogio = limite_s, relogio
        self.ultimo = relogio()

    def ok(self) -> None:
        self.ultimo = self.relogio()

    def vencido(self, lendo: bool) -> bool:
        agora = self.relogio()
        if not lendo:                       # standby nao le: o relogio so conta a partir da ativacao
            self.ultimo = agora
            return False
        return agora - self.ultimo > self.limite_s

    def parado_ha(self) -> float:
        return self.relogio() - self.ultimo


WATCHDOG = PollingWatchdog()


def _sair(codigo: int) -> None:
    logging.shutdown()
    os._exit(codigo)


def vigiar(lendo: Callable[[], bool], wd: PollingWatchdog = WATCHDOG, sair: Callable[[int], None] = _sair,
           intervalo_s: float = WATCHDOG_CHECK_S) -> threading.Thread:
    """Thread daemon (vive mesmo com o loop do asyncio travado): se vencer, loga e sai != 0 para o supervisor subir o bot."""
    def corpo() -> None:
        while True:
            time.sleep(intervalo_s)
            if wd.vencido(lendo()):
                log.critical("WATCHDOG: nenhum getUpdates concluiu em %.0fs (limite %.0fs); saindo com %d para o supervisor reiniciar",
                             wd.parado_ha(), wd.limite_s, WATCHDOG_EXIT)
                sair(WATCHDOG_EXIT)
                return
    t = threading.Thread(target=corpo, name="polling-watchdog", daemon=True)
    t.start()
    return t


class BotVigiado(ExtBot):
    """ExtBot que avisa o watchdog a cada getUpdates respondido pelo Telegram (mesmo sem mensagem ou com erro de API)."""

    async def get_updates(self, *args, **kwargs):
        try:
            res = await super().get_updates(*args, **kwargs)
        except (NetworkError, TimedOut):
            raise
        except TelegramError:                  # 409 e afins: o Telegram respondeu, so a falha de transporte deixa o relogio correr
            WATCHDOG.ok()
            raise
        WATCHDOG.ok()
        return res


def criar_bot(token: str) -> BotVigiado:
    """Bot com pool grande para envio e requisicao propria, com timeout finito, para o getUpdates."""
    return BotVigiado(
        token=token,
        request=HTTPXRequest(connection_pool_size=256),
        get_updates_request=HTTPXRequest(connection_pool_size=1, connect_timeout=10.0,
                                         read_timeout=POLL_READ_TIMEOUT_S, write_timeout=10.0,
                                         pool_timeout=5.0))


class ErroPolling:
    """error_callback do PTB: Conflict vai para o dono da decisao, falha de rede vira 1 linha por janela, o resto mantem o traceback."""

    def __init__(self, ao_conflito: Callable[[], None], relogio: Callable[[], float] = time.monotonic):
        self.ao_conflito, self.relogio = ao_conflito, relogio
        self.ultimo_log: float | None = None
        self.suprimidos = 0

    def __call__(self, exc: BaseException) -> None:
        if isinstance(exc, Conflict):
            log.warning("409 Conflict: outro leitor no mesmo token")
            self.ao_conflito()
        elif erro_de_rede(exc) and not isinstance(exc, BadRequest):
            self._rede(exc)
        else:
            log.error("Exception happened while polling for updates.", exc_info=exc)

    def _rede(self, exc: BaseException) -> None:
        agora = self.relogio()
        if self.ultimo_log is not None and agora - self.ultimo_log < REDE_LOG_S:
            self.suprimidos += 1
            return
        extra = f" ({self.suprimidos} iguais suprimidos)" if self.suprimidos else ""
        log.warning("polling sem rede: %s: %s%s", type(exc).__name__, exc, extra)
        self.ultimo_log, self.suprimidos = agora, 0
