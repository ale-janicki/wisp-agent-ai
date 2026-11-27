import asyncio
import json
import subprocess
import sys
import types
from pathlib import Path

import pytest

from wisp_bot import config, ctl, hosting, topicos


def _write(tmp_path: Path, telegram: dict | None = None, **top) -> dict:
    token = tmp_path / "secrets/telegram-token"
    token.parent.mkdir(parents=True, exist_ok=True)
    token.write_text("123:from-file\n")
    tg = {"chat_id": -1001, "user_id": 1, "token_file": str(token),
          "state_dir": str(tmp_path / "state"), **(telegram or {})}
    path = tmp_path / "wisp.json"
    path.write_text(json.dumps({"brain": str(tmp_path / "brain"), "telegram": tg, **top}))
    return {"WISP_CONFIG": str(path), "HOME": str(tmp_path)}


def _constants(env: dict) -> dict:
    code = ("import json; from wisp_bot import abrir, ctl, hosting, store, topicos; "
            "print(json.dumps({'store': str(store.STORE), 'ctl': str(ctl.DIR), 'abrir': str(abrir.FILA), "
            "'hosting': str(hosting.DIR), 'brain': str(topicos.BRAIN), "
            "'topics_dir': str(topicos.DIR), 'topics_rel': topicos.REL}))")
    out = subprocess.run([sys.executable, "-c", code], env={**env, "PATH": "/usr/bin:/bin"},
                         capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    return json.loads(out.stdout)


def test_missing_user_id_refuses_start(tmp_path):
    env = _write(tmp_path)
    raw = json.loads(Path(env["WISP_CONFIG"]).read_text())
    del raw["telegram"]["user_id"]
    Path(env["WISP_CONFIG"]).write_text(json.dumps(raw))
    with pytest.raises(config.ConfigError, match="user_id"):
        config.load_bot_config(env)


def test_token_read_from_file_not_env(tmp_path):
    env = {**_write(tmp_path), "WISP_TG_TOKEN": "999:from-env"}
    assert config.load_bot_config(env).token == "123:from-file"


def test_paths_follow_state_dir(tmp_path):
    env = _write(tmp_path)
    state = tmp_path / "state"
    assert config.load_bot_config(env).state_dir == state
    got = _constants(env)
    assert got["store"] == str(state / "topics.json")
    assert got["ctl"] == str(state / "ctl")
    assert got["abrir"] == str(state / "abrir")
    assert got["hosting"] == str(state)


def test_topics_dir_under_brain(tmp_path):
    env = _write(tmp_path, {"topics_rel": "notas/topicos"})
    cfg = config.load_bot_config(env)
    assert cfg.topics_dir == tmp_path / "brain/notas/topicos" and cfg.topics_rel == "notas/topicos"
    got = _constants(env)
    assert got["brain"] == str(tmp_path / "brain")
    assert got["topics_dir"] == str(tmp_path / "brain/notas/topicos")
    assert got["topics_rel"] == "notas/topicos"


def test_solo_activates_without_ssh(monkeypatch):
    async def nunca(script):
        raise AssertionError("solo never opens ssh")
    monkeypatch.setattr(hosting, "MODO", "solo")
    monkeypatch.setattr(hosting, "_pc_ssh", nunca)
    monkeypatch.setattr(hosting, "BATIDA_S", 0.01)
    h = hosting.Hosting(object(), None, None)
    chamadas = []

    async def ativar(motivo):
        chamadas.append(motivo)
        h.estado = "active"
    monkeypatch.setattr(h, "ativar", ativar)

    async def rodar_um_pouco():
        t = asyncio.ensure_future(h.rodar())
        await asyncio.sleep(0.1)
        t.cancel()
        await asyncio.gather(t, return_exceptions=True)
    asyncio.run(rodar_um_pouco())
    assert len(chamadas) == 1
    assert hosting.ler_estado_local()["state"] == "active"


def _sem_subprocesso(monkeypatch):
    async def proibido(*a, **k):
        raise AssertionError(f"no subprocess expected: {a!r}")
    monkeypatch.setattr(asyncio, "create_subprocess_exec", proibido)


def test_topicos_sync_noop_without_cmd(monkeypatch):
    _sem_subprocesso(monkeypatch)
    monkeypatch.setattr(topicos, "SYNC", None)
    assert asyncio.run(topicos.pull()) is True
    assert asyncio.run(topicos.push_agora()) is True


def test_alert_noop_without_cmd(monkeypatch):
    from wisp_bot import claude_runner
    _sem_subprocesso(monkeypatch)
    monkeypatch.setattr(hosting, "ALERTA", None)
    assert asyncio.run(hosting.rodar_alerta("add", "--nivel", "red", "--chave", "x", "texto")) is False
    assert asyncio.run(claude_runner._alerta("resolve", "x")) is False


BASELINE = {
    "encerrar": ({"thread": "7"}, {"id", "op", "thread", "at"}),
    "vincular": ({"session_id": "s1", "nome": "n", "cwd": "~/x"}, {"id", "op", "session_id", "nome", "cwd", "at"}),
    "desvincular": ({"session_id": "s1"}, {"id", "op", "session_id", "at"}),
}


@pytest.mark.parametrize("op", sorted(BASELINE))
def test_ctl_request_shape_unchanged(tmp_path, monkeypatch, op):
    monkeypatch.setattr(ctl, "DIR", tmp_path / "ctl")
    monkeypatch.setattr(ctl, "DONE", tmp_path / "ctl/done")
    args, keys = BASELINE[op]
    id_ = ctl.pedir(op, **args)
    pedido = json.loads((tmp_path / "ctl" / f"{id_}.json").read_text())
    assert set(pedido) == keys and pedido["op"] == op and pedido["id"] == id_
    assert all(pedido[k] == v for k, v in args.items())
    ctl.gravar_done(id_, {"ok": True, "thread_id": 7})
    assert json.loads((tmp_path / "ctl/done" / f"{id_}.json").read_text()) == {"ok": True, "thread_id": 7}
    assert ctl.ler_done(id_) == {"ok": True, "thread_id": 7}


def test_persona_comes_from_top_level(tmp_path):
    env = _write(tmp_path, {"persona": "Wisp"}, persona="Luna")
    assert config.load_bot_config(env).persona == "Luna"
    assert config.load_settings(env).persona == "Luna"


@pytest.mark.parametrize("falta", ["user", "pc_name"])
def test_pair_requires_user_and_pc_name(tmp_path, falta):
    par = {"user": "u", "pc_name": "pc-test", "config": str(tmp_path / "pair.conf")}
    del par[falta]
    env = _write(tmp_path, {"hosting": "pair", "pair": par})
    with pytest.raises(config.ConfigError, match=f"pair.{falta}"):
        config.load_bot_config(env)


def _solo(monkeypatch):
    monkeypatch.setattr(hosting, "MODO", "solo")

    def proibido(*a, **k):
        raise AssertionError(f"no process expected in solo: {a!r}")
    monkeypatch.setattr(subprocess, "Popen", proibido)
    monkeypatch.setattr(subprocess, "run", proibido)


def test_solo_never_spawns_for_the_pc(monkeypatch, tmp_path):
    from wisp_bot import sessao
    _solo(monkeypatch)
    assert hosting.pc_argv() is None
    assert hosting.pc_argv(windows=True) is None
    assert sessao.ssh_pc("true", 5) == (2, "")
    with pytest.raises(RuntimeError, match="uma máquina só"):
        sessao.buscar_do_pc("11111111-2222-4333-8444-555555555555", str(tmp_path))


def test_pair_error_names_the_configured_pair_file(monkeypatch, tmp_path):
    from wisp_bot import sessao
    monkeypatch.setattr(hosting, "pc_argv", lambda *a, **k: None)
    with pytest.raises(RuntimeError) as e:
        sessao.buscar_do_pc("11111111-2222-4333-8444-555555555555", str(tmp_path))
    assert str(hosting.PC_CFG) in str(e.value) and "pc-remote" not in str(e.value)


@pytest.mark.parametrize("modo,esperado", [("solo", (f"terminal-{hosting.HOST}",)),
                                           ("pair", ("terminal-mac", "terminal-pc"))])
def test_terminal_destinations_follow_hosting(monkeypatch, modo, esperado):
    monkeypatch.setattr(hosting, "MODO", modo)
    assert ctl.destinos() == esperado


def test_solo_terminal_on_other_machine_says_one_sentence(monkeypatch):
    from wisp_bot import bot
    monkeypatch.setattr(hosting, "MODO", "solo")
    outro = "pc" if hosting.HOST == "mac" else "mac"
    respostas = []

    async def reply(update, texto, thread_id):
        respostas.append(texto)

    async def soltar(*a, **k):
        raise AssertionError("solo never hands the topic to another machine")
    monkeypatch.setattr(bot, "reply", reply)
    monkeypatch.setattr(bot, "soltar_topico", soltar)
    monkeypatch.setattr(bot.store, "get", lambda key: object())
    monkeypatch.setattr(bot, "topic_key", lambda u: ("-1001:9", 9))
    upd = types.SimpleNamespace(effective_chat=types.SimpleNamespace(id=-1001))
    asyncio.run(bot.cmd_terminal(upd, types.SimpleNamespace(bot=None), f"terminal-{outro}"))
    assert len(respostas) == 1 and "uma máquina só" in respostas[0]


@pytest.mark.parametrize("modo", ["solo", "pair"])
def test_leaving_telegram_points_to_a_command_that_works(monkeypatch, modo):
    from wisp_bot import bot
    monkeypatch.setattr(hosting, "MODO", modo)
    t = types.SimpleNamespace(name="x", session_id="s1", cwd="/tmp")
    texto = bot.texto_saiu_do_telegram(t, 9, "terminal-pc", "arquivado")
    if modo == "pair":
        assert "puxar" not in texto and "claude --resume" not in texto and "app do Wisp" in texto
    else:
        assert "claude --resume s1" in texto


@pytest.mark.parametrize("modo", ["solo", "pair"])
def test_topic_rule_is_generic(monkeypatch, modo):
    from wisp_bot import bot
    monkeypatch.setattr(hosting, "MODO", modo)
    regra = bot.regra_para("-1001:9", -1001, 9, "notas/topico-9-x.md")
    for proibido in ("/commit-push", "/e2e", "hook"):
        assert proibido not in regra
    if modo == "pair":
        assert "no PC ou no Mac" in regra
    else:
        assert "nesta máquina" in regra and "PC ou no Mac" not in regra


def test_default_paths_per_platform(monkeypatch):
    monkeypatch.setenv("LOCALAPPDATA", "C:\\L")
    monkeypatch.setenv("APPDATA", "C:\\A")
    assert config.default_state_dir("win32") == "C:\\L\\wisp\\state\\bot"
    assert config.default_conversations("win32") == "C:\\A\\Wisp\\conversations.json"
    assert config.default_state_dir("darwin") == "~/.local/state/wisp/bot"
    assert config.default_conversations("darwin") == "~/Library/Application Support/Wisp/conversations.json"
