import json
from pathlib import Path

import pytest

from wisp_bot import config

FIXTURE = json.loads((Path(__file__).parents[2] / "cli/tests/fixtures/contract/wisp-folder-layout.json").read_text("utf-8"))
NAMES = ("conversas", "reunioes", "brain", "modelos", "anexos", "skills", "ferramentas", "logs")
FILES = {"agente": "agente.md", "guardrails": "guardrails.toml", "modelos": "modelos.toml"}


def _fill(value, home):
    return value.replace("{home}", str(home))


@pytest.mark.parametrize("case", FIXTURE["cases"], ids=lambda c: c["name"])
def test_resolver_matches_the_contract(case, tmp_path):
    env = {"HOME": str(tmp_path), **{k: _fill(v, tmp_path) for k, v in case["env"].items()}}
    expect = {k: _fill(v, tmp_path) for k, v in case["expect"].items()}
    assert str(config.config_path(env)) == expect["config_file"]
    found = config.folder_layout(case["config"] or {}, env)
    assert str(found["root"]) == expect["root"]
    for name in NAMES:
        assert str(found[name]) == expect["modelos_pasta" if name == "modelos" else name], name
    for key, name in FILES.items():
        assert str(found[name]) == expect[key], key


def test_the_bot_reads_attachments_from_the_folder(tmp_path):
    raw = {"wisp_dir": str(tmp_path / "W"), "telegram": {"chat_id": 1, "user_id": 1, "token_file": "t"}}
    built = config._build(raw, {"HOME": str(tmp_path)}, strict=False)
    assert built.anexos == tmp_path / "W/anexos"
    assert built.brain == tmp_path / "W/brain"
