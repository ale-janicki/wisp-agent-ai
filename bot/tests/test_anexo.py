"""Testes do download de anexo: midia e File falsos, sleep sem espera."""
import asyncio
from unittest import mock

import pytest
from telegram.error import BadRequest, TimedOut

from wisp_bot import bot


class FakeFile:
    def __init__(self, falhas, erro):
        self.falhas, self.erro, self.chamadas = falhas, erro, 0

    async def download_to_drive(self, destino, **kw):
        self.chamadas += 1
        if self.chamadas <= self.falhas:
            raise self.erro
        destino.write_bytes(b"x")


class FakeMidia:
    file_id = "fid"

    def __init__(self, f):
        self.f = f

    async def get_file(self, **kw):
        return self.f


def _baixar(f, destino):
    with mock.patch.object(bot.asyncio, "sleep", new=mock.AsyncMock()):
        asyncio.run(bot._baixar_anexo(FakeMidia(f), destino))


def test_sucesso_apos_dois_timeouts(tmp_path):
    f = FakeFile(2, TimedOut("Timed out"))
    _baixar(f, tmp_path / "a.jpg")
    assert f.chamadas == 3 and (tmp_path / "a.jpg").exists()


def test_desiste_apos_tres_timeouts(tmp_path):
    f = FakeFile(9, TimedOut("Timed out"))
    with pytest.raises(TimedOut):
        _baixar(f, tmp_path / "a.jpg")
    assert f.chamadas == 3


def test_bad_request_nao_repete(tmp_path):
    f = FakeFile(9, BadRequest("File is too big"))
    with pytest.raises(BadRequest):
        _baixar(f, tmp_path / "a.jpg")
    assert f.chamadas == 1
