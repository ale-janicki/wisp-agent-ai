import errno
import json
import os
import time

import pytest

from wisp import migrate_folder as migrate
from wisp.config import WispConfig, load_config
from wisp.migrate_folder import LOG, NOTE, PART, meetings_pending, migrate_folder, migrate_meetings
from wisp.paths import WispPaths


def _paths(home):
    return WispPaths.for_os("Darwin", home, {})


def _app_anexos(home):
    return home / "Library/Application Support/Wisp/anexos"


def _bot_anexos(home):
    return home / ".local/state/wisp/bot/anexos"


def _put(path, text="x"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def _age(path, seconds=3600):
    stamp = time.time() - seconds
    for folder, dirs, names in os.walk(path, topdown=False):
        for name in (*names, *dirs):
            os.utime(os.path.join(folder, name), (stamp, stamp), follow_symlinks=False)
    os.utime(path, (stamp, stamp))


def test_fresh_home_has_nothing_to_move(fake_home):
    report = migrate_folder(_paths(fake_home), WispConfig())
    assert report.status == "skipped"
    assert not (fake_home / "Wisp").exists()


def test_partial_home_moves_what_exists_and_leaves_a_note_and_a_log(fake_home):
    _put(_app_anexos(fake_home) / "2026-11-01/a.png", "app")
    _put(_bot_anexos(fake_home) / "2026-11-02/b.pdf", "bot")
    report = migrate_folder(_paths(fake_home), WispConfig())
    root = fake_home / "Wisp"
    assert report.status == "done" and report.data["moved"] == "2" and report.data["conflicts"] == "0"
    assert (root / "anexos/2026-11-01/a.png").read_text() == "app"
    assert (root / "anexos/2026-11-02/b.pdf").read_text() == "bot"
    assert not (_app_anexos(fake_home) / "2026-11-01").exists()
    for old in (_app_anexos(fake_home), _bot_anexos(fake_home)):
        assert str(root / "anexos") in (old / NOTE).read_text()
    log = (root / "logs" / LOG).read_text()
    assert log.count("moveu") == 2 and "a.png" not in log and "2026-11-01" in log


def test_a_conflict_keeps_both_and_reports(fake_home):
    _put(_app_anexos(fake_home) / "dia/a.txt", "velho")
    _put(fake_home / "Wisp/anexos/dia/a.txt", "novo")
    _put(_app_anexos(fake_home) / "outro/b.txt", "b")
    report = migrate_folder(_paths(fake_home), WispConfig())
    assert report.data["moved"] == "1" and report.data["conflicts"] == "1"
    assert (fake_home / "Wisp/anexos/dia/a.txt").read_text() == "novo"
    assert (_app_anexos(fake_home) / "dia/a.txt").read_text() == "velho"
    assert (fake_home / "Wisp/anexos/outro/b.txt").read_text() == "b"
    assert "conflito" in (fake_home / "Wisp/logs" / LOG).read_text()


def test_rerun_is_a_no_op_and_does_not_repeat_the_conflict_in_the_log(fake_home):
    _put(_app_anexos(fake_home) / "dia/a.txt", "velho")
    _put(fake_home / "Wisp/anexos/dia/a.txt", "novo")
    _put(_bot_anexos(fake_home) / "z.txt", "z")
    migrate_folder(_paths(fake_home), WispConfig())
    log = fake_home / "Wisp/logs" / LOG
    first = log.read_text()
    again = migrate_folder(_paths(fake_home), WispConfig())
    assert again.data["moved"] == "0" and again.data["conflicts"] == "1"
    assert log.read_text() == first
    assert (fake_home / "Wisp/anexos/z.txt").read_text() == "z"


def _force_exdev_once(monkeypatch, name):
    real = migrate._exclusive
    calls = []

    def fake(src, dst):
        if not calls and dst.name == name:
            calls.append(1)
            raise OSError(errno.EXDEV, "cross-device")
        return real(src, dst)

    monkeypatch.setattr(migrate, "_exclusive", fake)


def _force_exdev_always(monkeypatch):
    real = migrate._exclusive

    def fake(src, dst):
        if not src.name.startswith(PART):
            raise OSError(errno.EXDEV, "cross-device")
        return real(src, dst)

    monkeypatch.setattr(migrate, "_exclusive", fake)


def test_interrupted_cross_volume_copy_resumes(fake_home, monkeypatch):
    _put(_bot_anexos(fake_home) / "dia/a.txt", "dados")
    _force_exdev_once(monkeypatch, "dia")
    leftover = fake_home / "Wisp/anexos" / (PART + "dia")
    _put(leftover / "lixo.txt", "meia copia")
    report = migrate_folder(_paths(fake_home), WispConfig())
    assert report.status == "done"
    assert (fake_home / "Wisp/anexos/dia/a.txt").read_text() == "dados"
    assert not leftover.exists()
    assert not (_bot_anexos(fake_home) / "dia").exists()


def test_cross_volume_copy_is_fully_synced_before_the_source_goes(fake_home, monkeypatch):
    import fcntl
    import stat

    _put(_bot_anexos(fake_home) / "dia/a.txt", "dados")
    _force_exdev_once(monkeypatch, "dia")
    full, plain = [], []
    real_fcntl, real_fsync = fcntl.fcntl, os.fsync
    monkeypatch.setattr(fcntl, "fcntl", lambda fd, cmd, *a: (full.append((cmd, os.fstat(fd).st_mode)), real_fcntl(fd, cmd, *a))[1])
    monkeypatch.setattr(os, "fsync", lambda fd: (plain.append(os.fstat(fd).st_mode), real_fsync(fd))[1])
    migrate_folder(_paths(fake_home), WispConfig())
    modes = [m for cmd, m in full if cmd == fcntl.F_FULLFSYNC] + plain
    assert any(stat.S_ISREG(m) for m in modes) and sum(stat.S_ISDIR(m) for m in modes) >= 2
    if os.uname().sysname == "Darwin":
        assert any(cmd == fcntl.F_FULLFSYNC and stat.S_ISREG(m) for cmd, m in full)


def test_a_source_that_cannot_be_removed_is_reported_not_hidden(fake_home, monkeypatch):
    _put(_bot_anexos(fake_home) / "dia/a.txt", "dados")
    _force_exdev_once(monkeypatch, "dia")
    monkeypatch.setattr(migrate, "_remove_source", lambda src: [f"{src}: Permission denied"])
    report = migrate_folder(_paths(fake_home), WispConfig())
    assert report.status == "failed" and report.data["failed"] == "1"
    assert (fake_home / "Wisp/anexos/dia/a.txt").read_text() == "dados"
    assert "parcial" in (fake_home / "Wisp/logs" / LOG).read_text()


def test_a_move_never_renames_onto_a_path_that_may_exist(fake_home, monkeypatch):
    _put(_app_anexos(fake_home) / "dia/a.txt", "a")
    _put(_app_anexos(fake_home) / "b.txt", "b")
    monkeypatch.setattr(os, "rename", lambda *a, **k: (_ for _ in ()).throw(AssertionError("os.rename")))
    report = migrate_folder(_paths(fake_home), WispConfig())
    assert report.data["moved"] == "2"


def test_each_item_is_logged_as_it_moves(fake_home, monkeypatch):
    _put(_app_anexos(fake_home) / "a/x.txt")
    _put(_app_anexos(fake_home) / "b/x.txt")
    real = migrate._place
    calls = []

    def place(src, dst, budget=None):
        if calls:
            raise KeyboardInterrupt
        calls.append(1)
        return real(src, dst, budget)

    monkeypatch.setattr(migrate, "_place", place)
    with pytest.raises(KeyboardInterrupt):
        migrate_folder(_paths(fake_home), WispConfig())
    assert (fake_home / "Wisp/logs" / LOG).read_text().count("moveu") == 1


def test_the_note_lists_only_what_moved(fake_home):
    _put(_app_anexos(fake_home) / "dia/a.txt", "velho")
    _put(fake_home / "Wisp/anexos/dia/a.txt", "novo")
    _put(_app_anexos(fake_home) / "novo/b.txt", "b")
    migrate_folder(_paths(fake_home), WispConfig())
    note = (_app_anexos(fake_home) / NOTE).read_text()
    assert "- novo" in note and "- dia" not in note


def test_a_conflict_alone_leaves_no_note(fake_home):
    _put(_app_anexos(fake_home) / "dia/a.txt", "velho")
    _put(fake_home / "Wisp/anexos/dia/a.txt", "novo")
    migrate_folder(_paths(fake_home), WispConfig())
    assert not (_app_anexos(fake_home) / NOTE).exists()


def test_launch_migration_never_moves_recordings(fake_home):
    _put(fake_home / "Wisp/reunioes/2026-11-01_10-00-00/meta.json", "{}")
    cfg = WispConfig(wisp_dir=str(fake_home / "Dados/Meu Wisp"))
    migrate_folder(_paths(fake_home), cfg)
    assert (fake_home / "Wisp/reunioes/2026-11-01_10-00-00/meta.json").is_file()
    assert not (fake_home / "Dados/Meu Wisp/reunioes").exists()
    assert not (fake_home / "Wisp/reunioes" / NOTE).exists()


def test_the_explicit_recordings_move_reports_progress_and_resumes(fake_home):
    for name in ("a", "b", "c"):
        _put(fake_home / f"Wisp/reunioes/{name}/meta.json", name)
    cfg = WispConfig(wisp_dir=str(fake_home / "Dados/Meu Wisp"))
    _age(fake_home / "Wisp/reunioes")
    paths = _paths(fake_home)
    assert meetings_pending(paths, cfg) == 3
    events = []
    first = migrate_meetings(paths, cfg, lambda done, total, name: events.append((done, total, name)))
    assert first.data["moved"] == "3" and events == [(1, 3, "a"), (2, 3, "b"), (3, 3, "c")]
    assert (fake_home / "Dados/Meu Wisp/reunioes/b/meta.json").read_text() == "b"
    assert meetings_pending(paths, cfg) == 0
    _put(fake_home / "Wisp/reunioes/d/meta.json", "d")
    _age(fake_home / "Wisp/reunioes")
    assert migrate_meetings(paths, cfg).data["moved"] == "1"


def test_the_recordings_move_has_no_size_cap(fake_home, monkeypatch):
    monkeypatch.setattr(migrate, "ENTRY_CAP", 1)
    _put(fake_home / "Wisp/reunioes/a/audio.m4a", "x" * 100)
    _age(fake_home / "Wisp/reunioes")
    cfg = WispConfig(wisp_dir=str(fake_home / "Dados/W"))
    assert migrate_meetings(_paths(fake_home), cfg).data["moved"] == "1"


def test_caps_apply_only_to_a_cross_volume_copy(fake_home, monkeypatch):
    monkeypatch.setattr(migrate, "ENTRY_CAP", 10)
    monkeypatch.setattr(migrate, "TOTAL_CAP", 10)
    monkeypatch.setattr(migrate, "_size", lambda path: (_ for _ in ()).throw(AssertionError("walked")))
    _put(_app_anexos(fake_home) / "grande/a.bin", "x" * 100)
    _put(_app_anexos(fake_home) / "grande2/a.bin", "x" * 100)
    report = migrate_folder(_paths(fake_home), WispConfig())
    assert report.data["moved"] == "2" and report.data["left"] == "0"
    assert (fake_home / "Wisp/anexos/grande/a.bin").is_file()


def test_a_big_cross_volume_item_is_left_and_reported_at_launch(fake_home, monkeypatch):
    monkeypatch.setattr(migrate, "ENTRY_CAP", 10)
    _force_exdev_always(monkeypatch)
    _put(_app_anexos(fake_home) / "grande/a.bin", "x" * 100)
    _put(_app_anexos(fake_home) / "pequeno/a.bin", "x")
    report = migrate_folder(_paths(fake_home), WispConfig())
    assert report.data["moved"] == "1" and report.data["left"] == "1"
    assert (_app_anexos(fake_home) / "grande/a.bin").is_file()
    assert "ficou" in (fake_home / "Wisp/logs" / LOG).read_text()
    again = migrate_folder(_paths(fake_home), WispConfig())
    assert again.data["left"] == "1"
    assert (fake_home / "Wisp/logs" / LOG).read_text().count("ficou") == 1


def test_the_total_budget_counts_only_what_is_copied(fake_home, monkeypatch):
    monkeypatch.setattr(migrate, "TOTAL_CAP", 150)
    _force_exdev_always(monkeypatch)
    for name in ("a", "b", "c"):
        _put(_app_anexos(fake_home) / f"{name}/f", "x" * 100)
    report = migrate_folder(_paths(fake_home), WispConfig())
    assert report.data["moved"] == "1" and report.data["left"] == "2"


def test_the_recordings_move_has_no_size_cap_even_across_volumes(fake_home, monkeypatch):
    monkeypatch.setattr(migrate, "ENTRY_CAP", 1)
    _force_exdev_always(monkeypatch)
    _put(fake_home / "Wisp/reunioes/a/audio.m4a", "x" * 100)
    _age(fake_home / "Wisp/reunioes")
    cfg = WispConfig(wisp_dir=str(fake_home / "Dados/W"))
    assert migrate_meetings(_paths(fake_home), cfg).data["moved"] == "1"


def _no_renamex(monkeypatch):
    def refuse(src, dst):
        raise OSError(errno.ENOTSUP, "Operation not supported")

    monkeypatch.setattr(migrate, "_mover_sem_sobrescrever", refuse)
    monkeypatch.setattr(migrate.sys, "platform", "darwin")


def test_without_renamex_a_directory_moves_through_an_exclusive_mkdir(fake_home, monkeypatch):
    _no_renamex(monkeypatch)
    _put(_app_anexos(fake_home) / "dia/sub/a.txt", "a")
    _put(_app_anexos(fake_home) / "dia/b.txt", "b")
    report = migrate_folder(_paths(fake_home), WispConfig())
    assert report.data["moved"] == "1"
    assert (fake_home / "Wisp/anexos/dia/sub/a.txt").read_text() == "a"
    assert (fake_home / "Wisp/anexos/dia/b.txt").read_text() == "b"
    assert not (_app_anexos(fake_home) / "dia").exists()


def test_without_renamex_a_file_moves_by_link_and_never_overwrites(fake_home, monkeypatch):
    _no_renamex(monkeypatch)
    _put(_app_anexos(fake_home) / "novo.txt", "n")
    _put(_app_anexos(fake_home) / "igual.txt", "velho")
    _put(fake_home / "Wisp/anexos/igual.txt", "do destino")
    _put(_app_anexos(fake_home) / "dia/x", "x")
    _put(fake_home / "Wisp/anexos/dia/y", "y")
    report = migrate_folder(_paths(fake_home), WispConfig())
    assert report.data["moved"] == "1" and report.data["conflicts"] == "2"
    assert (fake_home / "Wisp/anexos/igual.txt").read_text() == "do destino"
    assert (_app_anexos(fake_home) / "igual.txt").read_text() == "velho"
    assert (fake_home / "Wisp/anexos/dia/y").read_text() == "y"
    assert (_app_anexos(fake_home) / "dia/x").is_file()


def test_without_renamex_or_hard_links_a_file_is_created_exclusively_and_copied(fake_home, monkeypatch):
    _no_renamex(monkeypatch)
    monkeypatch.setattr(os, "link", lambda *a, **k: (_ for _ in ()).throw(OSError(errno.EPERM, "no links")))
    _put(_app_anexos(fake_home) / "novo.txt", "conteudo")
    _put(_app_anexos(fake_home) / "igual.txt", "velho")
    _put(fake_home / "Wisp/anexos/igual.txt", "do destino")
    report = migrate_folder(_paths(fake_home), WispConfig())
    assert report.data["moved"] == "1" and report.data["conflicts"] == "1"
    assert (fake_home / "Wisp/anexos/novo.txt").read_text() == "conteudo"
    assert not (_app_anexos(fake_home) / "novo.txt").exists()
    assert (fake_home / "Wisp/anexos/igual.txt").read_text() == "do destino"


def test_a_cleanup_error_is_reported_not_fatal(fake_home, monkeypatch):
    _put(_app_anexos(fake_home) / "dia/a.txt", "a")
    _put(_bot_anexos(fake_home) / "outro/b.txt", "b")
    monkeypatch.setattr(migrate, "_clear_stale", lambda folder: (_ for _ in ()).throw(PermissionError(errno.EACCES, "Permission denied")))
    report = migrate_folder(_paths(fake_home), WispConfig())
    assert report.status == "failed" and report.data["failed"] == "2"
    assert (_app_anexos(fake_home) / "dia/a.txt").is_file()
    assert "falhou" in (fake_home / "Wisp/logs" / LOG).read_text()


def test_a_destination_inside_its_source_is_skipped_and_reported(fake_home):
    _put(fake_home / "Wisp/reunioes/a/meta.json", "{}")
    cfg = WispConfig(wisp_dir=str(fake_home / "Wisp/reunioes"))
    paths = _paths(fake_home)
    assert meetings_pending(paths, cfg) == 0
    report = migrate_meetings(paths, cfg)
    assert report.data["skipped"] == "1" and report.data["moved"] == "0"
    assert (fake_home / "Wisp/reunioes/a/meta.json").is_file()
    assert not (fake_home / "Wisp/reunioes/reunioes").exists()
    assert "pulou" in (fake_home / "Wisp/reunioes/logs" / LOG).read_text()


def test_a_source_inside_its_destination_is_skipped(fake_home):
    _put(fake_home / "Wisp/reunioes/a/meta.json", "{}")
    cfg = WispConfig(wisp_dir=str(fake_home))
    assert migrate_meetings(_paths(fake_home), cfg).data["skipped"] == "0"
    cfg = WispConfig(wisp_dir=str(fake_home / "Wisp/reunioes/a"))
    assert migrate_meetings(_paths(fake_home), cfg).data["skipped"] == "1"


def test_the_legacy_brain_is_kept_when_the_folder_moves(fake_home):
    _put(fake_home / "Wisp/brain/nota.md", "n")
    cfg = WispConfig(wisp_dir=str(fake_home / "Dados/W"))
    report = migrate_folder(_paths(fake_home), cfg)
    assert cfg.brain == str(fake_home / "Wisp/brain") and "brain" in report.data
    assert load_config().brain == str(fake_home / "Wisp/brain")


def test_an_empty_legacy_brain_or_an_explicit_one_is_not_pinned(fake_home):
    (fake_home / "Wisp/brain").mkdir(parents=True)
    cfg = WispConfig(wisp_dir=str(fake_home / "Dados/W"))
    migrate_folder(_paths(fake_home), cfg)
    assert cfg.brain is None
    _put(fake_home / "Wisp/brain/nota.md", "n")
    explicit = WispConfig(wisp_dir=str(fake_home / "Dados/W"), brain=str(fake_home / "vault"))
    migrate_folder(_paths(fake_home), explicit)
    assert explicit.brain == str(fake_home / "vault")


def test_only_markdown_counts_as_a_brain_with_content(fake_home):
    brain = fake_home / "Wisp/brain"
    _put(brain / ".DS_Store")
    _put(brain / ".git/HEAD")
    _put(brain / ".obsidian/notas.md")
    cfg = WispConfig(wisp_dir=str(fake_home / "Dados/W"))
    migrate_folder(_paths(fake_home), cfg)
    assert cfg.brain is None
    _put(brain / "wisp/aprendizados.md")
    migrate_folder(_paths(fake_home), cfg)
    assert cfg.brain == str(brain)


def test_the_default_folder_keeps_an_unset_brain_unset(fake_home):
    _put(fake_home / "Wisp/brain/nota.md", "n")
    cfg = WispConfig()
    migrate_folder(_paths(fake_home), cfg)
    assert cfg.brain is None


def test_the_profile_attachments_key_follows_the_move(fake_home):
    profile = fake_home / ".config/wisp/profile.json"
    _put(profile, json.dumps({"blocks": {"telegram": {"attachments": str(_bot_anexos(fake_home)), "post": "p"}}, "x": 1}))
    migrate_folder(_paths(fake_home), WispConfig())
    data = json.loads(profile.read_text())
    assert data["blocks"]["telegram"]["attachments"] == str(fake_home / "Wisp/anexos")
    assert data["blocks"]["telegram"]["post"] == "p" and data["x"] == 1


def test_a_profile_pointing_elsewhere_is_left_alone(fake_home):
    profile = fake_home / ".config/wisp/profile.json"
    body = json.dumps({"blocks": {"telegram": {"attachments": "/Users/x/meus"}}})
    _put(profile, body)
    migrate_folder(_paths(fake_home), WispConfig())
    assert profile.read_text() == body


def test_setup_folder_runs_the_migration_and_creates_the_new_folders(fake_home):
    from wisp.runner import FakeRunner
    from wisp.setup.folder import setup_folder

    _put(_app_anexos(fake_home) / "dia/a.txt", "a")
    report = setup_folder(FakeRunner(), _paths(fake_home), WispConfig(), path=fake_home / "Wisp", dry_run=False)
    assert "1 itens movidos" in report.data["migrated"]
    for name in ("conversas", "reunioes", "anexos", "logs", "skills", "ferramentas"):
        assert (fake_home / "Wisp" / name).is_dir()
    assert (fake_home / "Wisp/anexos/dia/a.txt").read_text() == "a"


def test_the_cli_prints_progress_lines_then_the_report(fake_home, capsys):
    from wisp.cli import main

    cfgfile = fake_home / ".config/wisp/wisp.json"
    _put(cfgfile, json.dumps({"wisp_dir": str(fake_home / "Dados/W")}))
    _put(fake_home / "Wisp/reunioes/a/meta.json", "{}")
    _age(fake_home / "Wisp/reunioes")
    assert main(["folder", "migrate", "--reunioes", "--json"]) == 0
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert lines[0] == {"type": "progress", "done": 1, "total": 1, "item": "a"}
    assert lines[-1]["step"] == "folder-migrate" and lines[-1]["data"]["moved"] == "1"


def _recording(folder, status="recording"):
    _put(folder / "meta.json", json.dumps({"status": status}))
    _put(folder / "audio.caf", "x")


def test_the_recordings_move_refuses_while_a_recording_is_active(fake_home):
    _recording(fake_home / "Wisp/reunioes/ativa")
    _put(fake_home / "Wisp/reunioes/outra/meta.json", "{}")
    _age(fake_home / "Wisp/reunioes/outra")
    cfg = WispConfig(wisp_dir=str(fake_home / "Dados/W"))
    report = migrate_meetings(_paths(fake_home), cfg)
    assert report.status == "failed" and report.data == {"recording": "true"}
    assert (fake_home / "Wisp/reunioes/ativa/audio.caf").is_file()
    assert (fake_home / "Wisp/reunioes/outra/meta.json").is_file()
    assert not (fake_home / "Dados/W/reunioes").exists()


def test_a_crashed_recording_that_stopped_changing_moves_normally(fake_home):
    _recording(fake_home / "Wisp/reunioes/velha")
    _age(fake_home / "Wisp/reunioes")
    cfg = WispConfig(wisp_dir=str(fake_home / "Dados/W"))
    assert migrate_meetings(_paths(fake_home), cfg).data["moved"] == "1"


def test_an_entry_modified_in_the_last_minute_is_left_in_place(fake_home):
    _recording(fake_home / "Wisp/reunioes/finalizada", "transcribing")
    _put(fake_home / "Wisp/reunioes/antiga/meta.json", "{}")
    _age(fake_home / "Wisp/reunioes/antiga")
    cfg = WispConfig(wisp_dir=str(fake_home / "Dados/W"))
    report = migrate_meetings(_paths(fake_home), cfg)
    assert report.data["moved"] == "1" and report.data["left"] == "1"
    assert (fake_home / "Wisp/reunioes/finalizada/audio.caf").is_file()
    assert "modificada há pouco" in (fake_home / "Dados/W/logs" / LOG).read_text()


def test_an_old_folder_that_is_a_symlink_is_skipped_and_never_touched(fake_home):
    external = fake_home / "Disco/anexos"
    _put(external / "dia/a.txt", "a")
    link = _app_anexos(fake_home)
    link.parent.mkdir(parents=True)
    link.symlink_to(external)
    report = migrate_folder(_paths(fake_home), WispConfig())
    assert report.data["skipped"] == "1" and report.data["moved"] == "0"
    assert link.is_symlink() and (external / "dia/a.txt").read_text() == "a"
    assert not (link / NOTE).exists()
    assert "atalho" in (fake_home / "Wisp/logs" / LOG).read_text()


def test_relative_symlinks_in_a_moved_tree_still_resolve(fake_home):
    root = _app_anexos(fake_home)
    _put(root / "dia/real.txt", "real")
    _put(root / "fora.txt", "fora")
    (root / "dia/interno").symlink_to("real.txt")
    (root / "dia/para-irmao").symlink_to("../fora.txt")
    (root / "topo").symlink_to("fora.txt")
    migrate_folder(_paths(fake_home), WispConfig())
    new = fake_home / "Wisp/anexos"
    assert (new / "dia/interno").read_text() == "real"
    assert (new / "dia/para-irmao").read_text() == "fora"
    assert (new / "topo").read_text() == "fora"


def test_relative_symlinks_pointing_outside_the_folder_are_rewritten(fake_home):
    root = _app_anexos(fake_home)
    _put(fake_home / "Documentos/nota.txt", "nota")
    (root / "dia").mkdir(parents=True)
    (root / "dia/nota").symlink_to(os.path.relpath(fake_home / "Documentos/nota.txt", root / "dia"))
    migrate_folder(_paths(fake_home), WispConfig())
    assert (fake_home / "Wisp/anexos/dia/nota").read_text() == "nota"


def test_relative_symlinks_survive_a_cross_volume_copy(fake_home, monkeypatch):
    root = _bot_anexos(fake_home)
    _put(root / "dia/real.txt", "real")
    _put(fake_home / "Documentos/nota.txt", "nota")
    (root / "dia/interno").symlink_to("real.txt")
    (root / "dia/nota").symlink_to(os.path.relpath(fake_home / "Documentos/nota.txt", root / "dia"))
    _force_exdev_once(monkeypatch, "dia")
    migrate_folder(_paths(fake_home), WispConfig())
    new = fake_home / "Wisp/anexos/dia"
    assert (new / "interno").read_text() == "real" and (new / "nota").read_text() == "nota"


def _case_insensitive(home):
    (home / "CaseProbe").mkdir()
    return (home / "caseprobe").exists()


def test_the_same_folder_in_a_different_case_is_the_same_folder(fake_home):
    if not _case_insensitive(fake_home):
        pytest.skip("case-sensitive volume")
    _put(fake_home / "Wisp/reunioes/a/meta.json", "{}")
    _age(fake_home / "Wisp/reunioes")
    cfg = WispConfig(wisp_dir=str(fake_home / "wisp"))
    paths = _paths(fake_home)
    assert migrate._same(fake_home / "Wisp/reunioes", fake_home / "wisp/reunioes")
    assert meetings_pending(paths, cfg) == 0
    report = migrate_meetings(paths, cfg)
    assert report.data["moved"] == "0" and report.data["skipped"] == "0"
    assert (fake_home / "Wisp/reunioes/a/meta.json").is_file()


def test_a_case_variant_destination_inside_the_source_is_nested(fake_home):
    if not _case_insensitive(fake_home):
        pytest.skip("case-sensitive volume")
    _put(fake_home / "Wisp/reunioes/a/meta.json", "{}")
    assert migrate._nested(fake_home / "WISP/reunioes", fake_home / "wisp/Reunioes/reunioes")
