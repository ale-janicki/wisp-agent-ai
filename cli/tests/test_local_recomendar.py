import json
from datetime import date
from pathlib import Path

import pytest
from local_fakes import FakeLLM, reply

from wisp import cli as wisp_cli
from wisp.config import WispConfig, save_config
from wisp.engines import read_active
from wisp.local import catalog as catalogs
from wisp.local import arch
from wisp.local import backend as backends
from wisp.local import fetch, guardrails, modelos, recomendar, storage
from wisp.local import tools as _tools  # noqa: F401

CONTRACT = Path(__file__).parent / "fixtures/contract/local-recommendation.json"
WISP_FOLDER = Path(guardrails.__file__).parents[1] / "wisp_folder"


def fixture() -> dict:
    return json.loads(CONTRACT.read_text())


def hardware(case: dict) -> recomendar.Hardware:
    return recomendar.Hardware(case["input"]["chip"], case["input"]["memory_bytes"], case["input"]["free_disk_bytes"])


def test_the_fixture_catalog_is_the_shipped_catalog():
    assert fixture()["catalog"] == catalogs.to_json(catalogs.load())


@pytest.mark.parametrize("case", fixture()["cases"], ids=lambda c: c["name"])
def test_the_recommendation_matches_the_contract_fixture(case):
    assert recomendar.recommend(hardware(case), catalogs.load()) == case["expect"]


def by_name() -> dict[str, dict]:
    return {c["name"]: c["expect"] for c in fixture()["cases"]}


def test_the_ranges_of_macs_get_the_expected_models():
    cases = by_name()
    assert cases["m1-8gb"]["best"]["tag"] == "qwen3:4b" and cases["m1-8gb"]["fastest"] is None
    assert cases["m2-16gb"]["best"]["tag"] == cases["m2-16gb"]["fastest"]["tag"] == "qwen3:8b"
    assert (cases["m3-pro-36gb"]["best"]["tag"], cases["m3-pro-36gb"]["fastest"]["tag"]) == ("qwen3:14b", "qwen3:8b")
    assert cases["m4-16gb"]["best"]["tag"] == "qwen3:8b" and cases["m4-16gb"]["best"]["tokens_per_second"] == 26
    assert (cases["m4-max-128gb"]["best"]["tag"], cases["m4-max-128gb"]["fastest"]["tag"]) == ("qwen3:32b", "qwen3:8b")
    assert cases["unknown-chip-16gb"]["best"]["words_per_second"] is None
    assert "sem estimativa" in cases["unknown-chip-16gb"]["best"]["reason"]
    assert cases["m4-16gb-low-disk"]["best"]["tag"] == "qwen3:4b" and cases["m4-16gb-low-disk"]["fastest"] is None
    assert cases["m1-4gb-nothing-fits"]["best"] is None and "Claude ou o Codex" in cases["m1-4gb-nothing-fits"]["notes"][0]


def test_when_only_the_disk_is_short_the_note_says_how_much():
    result = recomendar.recommend(recomendar.Hardware("Apple M4", 16 << 30, 2_000_000_000), catalogs.load())
    assert result["best"] is None and "faltam 5,3 GB" in result["notes"][0] and "Claude ou o Codex" in result["notes"][0]


def test_the_speed_is_the_published_bandwidth_over_the_size_and_a_chip_outside_the_table_has_none():
    model = catalogs.load().find("qwen3:8b")
    assert recomendar.bandwidth_gbs("Apple M4 Pro") == 273 and recomendar.tokens_per_second(273, model) == 59
    assert recomendar.bandwidth_gbs("Apple M4 Max") == 410 and recomendar.bandwidth_gbs("Apple M3 Ultra") == 800
    assert recomendar.bandwidth_gbs("Apple M12") is None and recomendar.bandwidth_gbs("Intel Core i9") is None
    assert recomendar.chip_family("apple m3 pro") == "M3 Pro" and recomendar.chip_family("Apple M1") == "M1"


def test_every_table_entry_is_a_chip_family_the_parser_can_find():
    for family in recomendar.APPLE_BANDWIDTH_GBS:
        assert recomendar.chip_family(f"Apple {family}") == family


@pytest.fixture
def folder(fake_home):
    root = fake_home / "Wisp"
    (root / "conversas").mkdir(parents=True)
    for name in ("guardrails.toml", "modelos.toml"):
        (root / name).write_text((WISP_FOLDER / name).read_text())
    save_config(WispConfig(wisp_dir=str(root)))
    return root


def lines(capsys) -> list[dict]:
    return [json.loads(l) for l in capsys.readouterr().out.splitlines()]


def test_the_recomendar_command_prints_the_same_json_for_given_hardware(folder, capsys):
    case = fixture()["cases"][3]
    argv = ["local", "recomendar", "--json", "--chip", case["input"]["chip"], "--memory-bytes", str(case["input"]["memory_bytes"]),
            "--free-disk-bytes", str(case["input"]["free_disk_bytes"])]
    assert wisp_cli.main(argv) == 0
    assert lines(capsys) == [case["expect"]]


def test_the_recomendar_command_reads_this_mac_when_nothing_is_given(folder, capsys, monkeypatch):
    monkeypatch.setattr(recomendar, "read_chip", lambda: "Apple M4")
    monkeypatch.setattr(recomendar, "read_memory", lambda: 16 << 30)
    monkeypatch.setattr(recomendar, "read_available", lambda: 0)
    monkeypatch.setattr(storage, "free_bytes", lambda path: 158_000_000_000)
    assert wisp_cli.main(["local", "recomendar", "--json"]) == 0
    assert lines(capsys)[0] == by_name()["m4-16gb"]


def install_qwen4b(folder):
    for item in catalogs.load().find("qwen3:4b").files:
        target = fetch.model_dir(folder, "qwen3:4b") / item["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("wb") as out:
            out.truncate(item["size"])
    shards = {item["path"]: item["path"] for item in catalogs.load().find("qwen3:4b").files if item["path"].endswith(".safetensors")}
    (fetch.model_dir(folder, "qwen3:4b") / "model.safetensors.index.json").write_text(json.dumps({"weight_map": shards}))


def test_ready_names_what_is_missing_in_order(folder, capsys, monkeypatch):
    monkeypatch.setattr(arch, "host_is_apple_silicon", lambda: False)
    assert wisp_cli.main(["local", "ready"]) == 0
    assert lines(capsys) == [{"type": "ready", "ready": False, "missing": arch.NEEDS_APPLE_SILICON}]
    monkeypatch.setattr(arch, "host_is_apple_silicon", lambda: True)
    monkeypatch.setattr(backends.importlib.util, "find_spec", lambda name: None)
    assert wisp_cli.main(["local", "ready"]) == 0
    assert lines(capsys) == [{"type": "ready", "ready": False, "missing": backends.MLX_MISSING}]
    monkeypatch.setattr(backends.importlib.util, "find_spec", lambda name: object())
    assert wisp_cli.main(["local", "ready"]) == 0
    assert lines(capsys)[0]["missing"] == "nenhum modelo local está ativo"
    modelos.write(folder, modelos.LocalState("qwen3:4b", ("qwen3:4b",)))
    assert wisp_cli.main(["local", "ready"]) == 0
    assert lines(capsys)[0]["missing"] == "o modelo qwen3:4b não está baixado"
    install_qwen4b(folder)
    monkeypatch.setattr(backends.MlxBackend, "ensure_running", lambda self, tag=None: None)
    assert wisp_cli.main(["local", "ready"]) == 0
    assert lines(capsys) == [{"type": "ready", "ready": True}]


def test_an_openai_backend_never_needs_apple_silicon_to_be_ready(folder, capsys, monkeypatch):
    monkeypatch.setattr(arch, "host_is_apple_silicon", lambda: False)
    with FakeLLM(tags={"qwen2.5-7b": 1}) as fake:
        assert wisp_cli.main(["local", "backend", "openai", "--url", fake.url, "--model", "qwen2.5-7b"]) == 0
        capsys.readouterr()
        assert wisp_cli.main(["local", "ready"]) == 0
    assert lines(capsys) == [{"type": "ready", "ready": True}]


def test_a_chip_that_is_not_apple_silicon_is_told_so_and_offered_the_url_backend():
    cases = by_name()
    for name in ("intel", "empty-chip"):
        result = cases[name]
        assert result["best"] is None and result["fastest"] is None and result["notes"] == [arch.NEEDS_APPLE_SILICON]
    assert arch.chip_is_apple_silicon("Apple M4 Pro") and not arch.chip_is_apple_silicon("Intel(R) Core(TM) i9") and not arch.chip_is_apple_silicon("")


def test_config_set_engine_away_from_local_stops_the_mlx_server(fake_home, capsys, monkeypatch):
    (fake_home / "Wisp/brain").mkdir(parents=True)
    save_config(WispConfig(wisp_dir=str(fake_home / "Wisp"), brain=str(fake_home / "Wisp/brain"), user_name="Rita", persona="Ada"))
    stopped = []
    monkeypatch.setattr("wisp.cli.stop_server", lambda: stopped.append(1))
    assert wisp_cli.main(["config", "set", "engine", "local", "--json"]) == 0
    assert stopped == []
    assert wisp_cli.main(["config", "set", "engine", "claude", "--json"]) == 0
    assert wisp_cli.main(["config", "set", "engine", "codex", "--json"]) == 0
    assert stopped == [1, 1]


def test_a_recorded_message_is_left_out_of_the_history_but_still_sent(folder, capsys, monkeypatch):
    path = folder / "conversas/c9.jsonl"
    entries = [
        {"v": 1, "at": "2026-11-21T10:00:00.000Z", "kind": "user", "surface": "telegram", "text": "antes"},
        {"v": 1, "at": "2026-11-21T10:00:01.000Z", "kind": "assistant", "surface": "telegram", "text": "resposta", "engine": "claude", "model": "x"},
        {"v": 1, "at": "2026-11-21T10:00:02.000Z", "kind": "user", "surface": "telegram", "text": "agora"},
    ]
    path.write_text("\n".join(json.dumps(e) for e in entries) + "\n")
    with FakeLLM([reply("feito")], tags={"qwen3:8b": 5}) as fake:
        monkeypatch.setattr(_tools, "load_servers", lambda f: ([], []))
        assert wisp_cli.main(["local", "backend", "openai", "--url", fake.url, "--model", "qwen3:8b"]) == 0
        capsys.readouterr()
        argv = ["local", "chat", "--message", "agora", "--conversation", "c9", "--no-record", "--recorded", "--approvals", "stdio"]
        monkeypatch.setattr("sys.stdin", __import__("io").StringIO(""))
        assert wisp_cli.main(argv) == 0
    sent = [(m["role"], m["content"]) for m in fake.chats()[0]["messages"] if m["role"] != "system"]
    assert sent == [("user", "antes"), ("assistant", "resposta"), ("user", f"<contexto>data de hoje: {date.today().isoformat()} (não mencione a data a menos que perguntem)</contexto>\nagora")]
    assert path.read_text().count("\n") == 3


def test_config_set_engine_accepts_local_and_keeps_the_local_table(fake_home, capsys):
    (fake_home / "Wisp/brain").mkdir(parents=True)
    save_config(WispConfig(wisp_dir=str(fake_home / "Wisp"), brain=str(fake_home / "Wisp/brain"), user_name="Rita", persona="Ada"))
    (fake_home / "Wisp/modelos.toml").write_text('ativo = "claude"\n\n[local]\nativo = "qwen3:8b"\ninstalados = ["qwen3:8b"]\n')
    assert wisp_cli.main(["config", "set", "engine", "local", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["data"]["engine"] == "local"
    assert read_active(fake_home / "Wisp") == "local"
    assert modelos.read(fake_home / "Wisp") == modelos.LocalState("qwen3:8b", ("qwen3:8b",))


def test_low_free_memory_recommends_one_model_lighter_and_says_why():
    catalog = catalogs.load()
    plenty = recomendar.recommend(recomendar.Hardware("Apple M4", 16 << 30, 100 << 30, 12 << 30), catalog)
    short = recomendar.recommend(recomendar.Hardware("Apple M4", 16 << 30, 100 << 30, 5 << 30), catalog)
    unknown = recomendar.recommend(recomendar.Hardware("Apple M4", 16 << 30, 100 << 30), catalog)
    assert plenty["best"]["tag"] == unknown["best"]["tag"] == "qwen3:8b" and recomendar.LOW_MEMORY_REASON not in plenty["best"]["reason"]
    assert short["best"]["tag"] == "qwen3:4b" and short["best"]["reason"].endswith("o Mac está com pouca memória livre agora")
    assert short["fastest"]["tag"] == "qwen3:8b"


def test_low_free_memory_keeps_the_only_model_that_fits():
    only = recomendar.recommend(recomendar.Hardware("Apple M1", 8 << 30, 100 << 30, 1 << 30), catalogs.load())
    assert only["best"]["tag"] == "qwen3:4b" and recomendar.LOW_MEMORY_REASON not in only["best"]["reason"]


def test_vm_stat_available_memory_sums_free_inactive_speculative_and_purgeable():
    sample = (
        "Mach Virtual Memory Statistics: (page size of 16384 bytes)\n"
        "Pages free:                               10.\n"
        "Pages active:                             999.\n"
        "Pages inactive:                           20.\n"
        "Pages speculative:                        3.\n"
        "Pages purgeable:                          7.\n"
    )
    assert recomendar.parse_available(sample) == 40 * 16384 and recomendar.parse_available("") == 0
