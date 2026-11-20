from pathlib import Path

import json

import pytest

from wisp.local import catalog as catalogs
from wisp.local import guardrails, modelos
from wisp.local.modelos import LocalState, ModelosError

SHIPPED_MODELOS = (guardrails.__file__ and __import__("pathlib").Path(guardrails.__file__).parents[1] / "wisp_folder" / "modelos.toml")


def test_the_catalog_has_sourced_sizes_and_valid_tiers():
    catalog = catalogs.load()
    assert "ollama.com/library/qwen3" in catalog.source
    assert len({m.tag for m in catalog.models}) == len(catalog.models) >= 4
    for m in catalog.models:
        assert m.tier in guardrails.TIERS and m.size_bytes > 0 and m.context_tokens >= 4096
        assert m.memory_bytes == m.size_bytes + m.memory_overhead_bytes and m.limitations and m.library_url.startswith("https://ollama.com/library/")
    assert catalog.find("qwen3:8b").size_bytes == 5_200_000_000 and catalog.disk_margin_bytes > 0


def test_an_unknown_tier_in_the_catalog_is_refused(tmp_path):
    raw = json.loads(catalogs.CATALOG_FILE.read_text())
    raw["models"][0]["tier"] = "gigante"
    bad = tmp_path / "catalog.json"
    bad.write_text(json.dumps(raw))
    with pytest.raises(ValueError, match="gigante"):
        catalogs.load(bad)


def test_a_model_outside_the_catalog_gets_the_safest_tier_and_context():
    catalog = catalogs.load()
    assert catalog.tier_of("llama3.2:3b") == "pequeno" and catalog.context_of("llama3.2:3b") == catalogs.FALLBACK_CONTEXT
    assert catalog.tier_of("qwen3:14b") == "medio"


def test_the_suggestion_names_the_next_bigger_model_or_the_cloud_ones():
    catalog = catalogs.load()
    assert "Qwen3 14B" in catalog.suggestion("qwen3:8b") and "Médio" in catalog.suggestion("qwen3:8b")
    assert catalog.suggestion("qwen3:32b") == catalogs.BIGGER_ELSEWHERE


def test_the_json_for_the_app_carries_the_memory_need():
    data = catalogs.to_json(catalogs.load())
    assert data["models"][0]["memory_bytes"] == data["models"][0]["size_bytes"] + data["models"][0]["memory_overhead_bytes"]


def test_the_shipped_modelos_file_reads_as_nothing_installed():
    from wisp.local.modelos import read

    assert SHIPPED_MODELOS.read_text().count("[local]") == 1
    folder = SHIPPED_MODELOS.parent
    assert read(folder) == LocalState("", ())


def test_writing_the_local_table_keeps_the_top_level_key_and_the_comments(tmp_path, fake_home):
    folder = fake_home / "Wisp"
    folder.mkdir()
    (folder / "modelos.toml").write_text('# mine\nativo = "codex"\n\n[local]\nativo = "old"\ninstalados = ["old"]\n\n[other]\nx = 1\n')
    modelos.write(folder, LocalState("qwen3:8b", ("qwen3:8b", "qwen3:4b")))
    text = (folder / "modelos.toml").read_text()
    assert text.startswith('# mine\nativo = "codex"\n') and "[other]\nx = 1" in text and '"old"' not in text
    assert modelos.read(folder) == LocalState("qwen3:8b", ("qwen3:8b", "qwen3:4b"))
    modelos.write(folder, LocalState("qwen3:8b", ("qwen3:8b",)))
    assert (folder / "modelos.toml").read_text().count("[local]") == 1


def test_the_state_helpers_never_duplicate_or_forget():
    state = modelos.with_installed(LocalState("", ()), "a")
    assert modelos.with_installed(state, "a") == state
    assert modelos.with_active(state, "a") == LocalState("a", ("a",))


def test_a_broken_modelos_file_is_refused_and_not_overwritten(fake_home):
    folder = fake_home / "Wisp"
    folder.mkdir()
    (folder / "modelos.toml").write_text("[local\n")
    with pytest.raises(ModelosError):
        modelos.write(folder, LocalState("a", ("a",)))
    assert (folder / "modelos.toml").read_text() == "[local\n"
    (folder / "modelos.toml").write_text('[local]\nativo = 3\n')
    with pytest.raises(ModelosError, match="instalados"):
        modelos.read(folder)


def test_the_catalog_fixture_the_app_decodes_is_what_the_cli_prints():
    fixture = json.loads((Path(__file__).parent / "fixtures/contract/local-catalog.json").read_text())
    expected = {**catalogs.to_json(catalogs.load()), "ollama": {"installed": False, "running": False}, "installed": [], "active": ""}
    assert fixture == expected
