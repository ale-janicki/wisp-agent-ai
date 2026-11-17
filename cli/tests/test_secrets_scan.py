import subprocess
import sys

import pytest

from wisp.secrets_scan import scan_paths, scan_text

SAMPLES = {
    "anthropic": "sk-ant-" + "a" * 10,
    "aws": "AKIA" + "B" * 16,
    "telegram": "123456789:" + "x" * 35,
    "github": "ghp_" + "c" * 36,
    "jwt": ".".join(["eyJ" + "d" * 12, "eyJ" + "e" * 12, "f" * 12]),
}


@pytest.mark.parametrize("sample", SAMPLES.values(), ids=SAMPLES.keys())
def test_matches_known_shapes(sample):
    hits = scan_text(f"token = {sample}\n")
    assert len(hits) == 1
    assert hits[0] == sample[:6] + "…"


def test_allows_aws_doc_example():
    assert scan_text("AKIAIOSFODNN7" + "EXAMPLE") == []


def test_clean_text_has_no_hits():
    assert scan_text("nothing to see here, just words") == []


def test_binary_skipped(tmp_path):
    binary = tmp_path / "blob.bin"
    binary.write_bytes(b"\x00" + SAMPLES["github"].encode())
    text = tmp_path / "note.txt"
    text.write_text(SAMPLES["github"])
    assert scan_paths([binary, text]) == {text: [SAMPLES["github"][:6] + "…"]}


def test_module_exit_code(tmp_path):
    clean = tmp_path / "clean.txt"
    clean.write_text("hello")
    dirty = tmp_path / "dirty.txt"
    dirty.write_text(SAMPLES["aws"])
    run = lambda *p: subprocess.run([sys.executable, "-m", "wisp.secrets_scan", *map(str, p)], capture_output=True, text=True)
    assert run(clean).returncode == 0
    result = run(clean, dirty)
    assert result.returncode == 1
    assert result.stdout.strip() == f"{dirty}: AKIABB…"
    assert SAMPLES["aws"] not in result.stdout


def test_broken_symlink_and_unreadable_file_are_reported_not_fatal(tmp_path):
    good = tmp_path / "good.txt"
    good.write_text(SAMPLES["github"])
    link = tmp_path / "dangling"
    link.symlink_to(tmp_path / "nowhere")
    locked = tmp_path / "locked.txt"
    locked.write_text("x")
    locked.chmod(0)
    try:
        found = scan_paths([link, locked, good])
    finally:
        locked.chmod(0o644)
    assert found[good] == [SAMPLES["github"][:6] + "…"]
    assert found[link] == ["unreadable"]
    assert found[locked] == ["unreadable"]


def test_module_reports_dangling_symlink(tmp_path):
    (tmp_path / "dangling").symlink_to(tmp_path / "nowhere")
    result = subprocess.run([sys.executable, "-m", "wisp.secrets_scan", str(tmp_path)], capture_output=True, text=True)
    assert result.returncode == 1
    assert "dangling: unreadable" in result.stdout
