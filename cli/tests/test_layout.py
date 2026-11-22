import json
from pathlib import Path

import pytest

from wisp.config import _default_path, load_config
from wisp.layout import SUBFOLDERS, layout_of

FIXTURE = json.loads((Path(__file__).parent / "fixtures/contract/wisp-folder-layout.json").read_text("utf-8"))
NAMES = ("conversas", "reunioes", "brain", "modelos_dir", "anexos", "skills", "ferramentas", "logs", "agente", "guardrails", "modelos")


def _fill(value, home):
    return value.replace("{home}", str(home))


@pytest.mark.parametrize("case", FIXTURE["cases"], ids=lambda c: c["name"])
def test_resolver_matches_the_contract(case, fake_home, monkeypatch):
    for key in ("WISP_CONFIG", "XDG_CONFIG_HOME"):
        monkeypatch.delenv(key, raising=False)
    for key, value in case["env"].items():
        monkeypatch.setenv(key, _fill(value, fake_home))
    expect = {k: _fill(v, fake_home) for k, v in case["expect"].items()}
    config = _default_path()
    assert str(config) == expect["config_file"]
    if case["config"] is not None:
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(json.dumps(case["config"]))
    layout = layout_of(load_config(), fake_home)
    assert str(layout.root) == expect["root"]
    for name in NAMES:
        assert str(getattr(layout, name)) == expect[name.replace("modelos_dir", "modelos_pasta")], name


def test_the_subfolder_names_are_the_documented_ones():
    assert SUBFOLDERS == ("conversas", "reunioes", "brain", "modelos", "anexos", "skills", "ferramentas", "logs")
