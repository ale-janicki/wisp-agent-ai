import pytest

from wisp.cli import main


def test_version(capsys):
    with pytest.raises(SystemExit) as e:
        main(["--version"])
    assert e.value.code == 0
    assert capsys.readouterr().out.strip() == "wisp 0.1.0"


def test_unknown_command_exits_2():
    with pytest.raises(SystemExit) as e:
        main(["nope"])
    assert e.value.code == 2


def test_doctor_json_survives_corrupt_config(fake_home, capsys):
    import json

    config = fake_home / ".config/wisp/wisp.json"
    config.parent.mkdir(parents=True)
    config.write_text("{not json")
    assert main(["doctor", "--json", "--only", "profile"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert [c["id"] for c in out["checks"]] == ["profile"]
    assert "wisp.json" in out["warning"]


def test_brain_colher_json_without_brain(fake_home, capsys):
    import json

    assert main(["brain", "colher", "--if-due", "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["colhidas"] == []
    assert out["puladas"][0]["motivo"] == "brain nao encontrado"


def test_brain_colher_requires_action():
    with pytest.raises(SystemExit) as e:
        main(["brain"])
    assert e.value.code == 2
