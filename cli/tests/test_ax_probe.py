import os
import platform
import shutil
import subprocess
from pathlib import Path

import pytest

PROBE = Path(__file__).resolve().parents[2] / "scripts/ax-probe"
COMMIT = "9302bb553e70512888a9053fd7aa52e23fa30d1e"
macos = pytest.mark.skipif(platform.system() != "Darwin" or not shutil.which("cc") or not shutil.which("sandbox-exec"), reason="needs macOS, cc and sandbox-exec")


def test_the_recorded_result_pins_the_codex_commit_and_blocks_what_ax_needs():
    assert COMMIT in (PROBE / "run.sh").read_text() and COMMIT in (PROBE / "README.md").read_text()
    sections = {}
    current = ""
    for line in (PROBE / "expected.txt").read_text().splitlines():
        if line.startswith("== "):
            current = line[3:]
            sections[current] = {}
        else:
            name, rest = line.split(" -> ")
            sections[current][name] = rest
    assert set(sections) == {"readonly", "workspace"}
    for profile in sections.values():
        for name in ("com.apple.tccd", "com.apple.dock.server", "com.apple.windowserver.active", "com.apple.coreservices.appleevents"):
            assert profile[name] == "kr=1100 (blocked)"
        assert profile["com.apple.cfprefsd.daemon"] == "kr=0 (REACHABLE)"


@macos
def test_the_probe_builds_reports_ax_trust_and_sees_a_blocked_lookup_under_sandbox_exec(tmp_path):
    binary = tmp_path / "probe"
    subprocess.run(["cc", "-Wno-deprecated-declarations", "-framework", "ApplicationServices", "-o", str(binary), str(PROBE / "probe.c")], check=True)
    name = "com.apple.windowserver.active"
    free = subprocess.run([str(binary), name, "com.apple.nonexistent.wisp.probe"], capture_output=True, text=True, timeout=30)
    assert free.stdout.splitlines()[0].startswith("AXIsProcessTrusted=")
    assert f"{name} -> kr=0 (REACHABLE)" in free.stdout and "nonexistent.wisp.probe -> kr=1102 (blocked)" in free.stdout
    profile = tmp_path / "deny.sb"
    profile.write_text(f'(version 1)\n(allow default)\n(deny mach-lookup (global-name "{name}"))\n')
    blocked = subprocess.run(["sandbox-exec", "-f", str(profile), str(binary), name], capture_output=True, text=True, timeout=30)
    assert f"{name} -> kr=1100 (blocked)" in blocked.stdout


@macos
@pytest.mark.skipif(os.environ.get("WISP_RUN_AX_PROBE") != "1", reason="clones the Codex repository; set WISP_RUN_AX_PROBE=1")
def test_the_full_probe_matches_the_recorded_output():
    out = subprocess.run(["bash", str(PROBE / "run.sh")], capture_output=True, text=True, timeout=300).stdout
    assert out == (PROBE / "expected.txt").read_text()
