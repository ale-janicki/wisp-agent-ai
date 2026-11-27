import os
import subprocess
import sys
import textwrap

import pytest

from wisp import compat

POSIX_ONLY = ("fcntl", "termios", "pwd")
MODULES = (
    "wisp.cli", "wisp.local.cli", "wisp_bot.bot", "wisp.aprendizados", "wisp.reuniao", "wisp.reuniao_brain",
    "wisp.brain_colher", "wisp.migrate_folder", "wisp.local.fetch", "wisp.local.approver", "wisp.local.tools",
    "wisp.send_gate", "wisp.doctor", "wisp.runner", "wisp_bot.store", "wisp_bot.session_lock", "wisp_bot.transcript",
    "wisp_bot.broker", "wisp_bot.hosting", "wisp_bot.codex_runner", "wisp_bot.local_runner", "wisp_bot.modelo",
    "wisp_bot.soul", "wisp_bot.sessao", "wisp_bot.topicos", "wisp_bot.colheita",
)

BLOCKER = textwrap.dedent("""
    import importlib, sys
    BLOCKED = {blocked!r}
    def importer():
        frame = sys._getframe(2)
        while frame and frame.f_globals.get("__name__", "").startswith(("importlib", "_frozen_importlib")):
            frame = frame.f_back
        return frame.f_globals.get("__name__", "") if frame else ""
    class Block:
        # Only our own packages are held to POSIX-free imports; a dependency guards its own import by sys.platform.
        def find_spec(self, name, path=None, target=None):
            if name.split(".")[0] in BLOCKED and importer().split(".")[0] in ("wisp", "wisp_bot", "__main__"):
                raise ModuleNotFoundError(f"No module named {{name!r}}", name=name)
    sys.meta_path.insert(0, Block())
    for name in BLOCKED:
        sys.modules.pop(name, None)
    for module in {modules!r}:
        importlib.import_module(module)
    print("imported", len(sys.modules))
""")


def test_modules_import_without_posix_only_stdlib():
    code = BLOCKER.format(blocked=POSIX_ONLY, modules=MODULES)
    done = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=120)
    assert done.returncode == 0, done.stderr[-2000:]
    assert done.stdout.startswith("imported")


def test_lock_contention_between_two_handles(tmp_path):
    path = tmp_path / "lock"
    first, second = open(path, "w"), open(path, "w")
    try:
        compat.lock_file(first)
        with pytest.raises(BlockingIOError):
            compat.lock_file(second, blocking=False)
        compat.unlock_file(first)
        compat.lock_file(second, blocking=False)
        compat.unlock_file(second)
    finally:
        first.close()
        second.close()


def test_lock_accepts_file_descriptor(tmp_path):
    with open(tmp_path / "lock", "w") as fh:
        compat.lock_file(fh.fileno(), exclusive=False)
        compat.unlock_file(fh.fileno())


def test_kill_process_tree_kills_group():
    proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], **compat.new_session_kwargs())
    compat.kill_process_tree(proc.pid, compat.SIGKILL)
    assert proc.wait(timeout=10) != 0


def test_platform_helpers():
    assert compat.IS_WINDOWS == (sys.platform == "win32")
    assert compat.current_uid() == (None if compat.IS_WINDOWS else os.getuid())
    assert isinstance(compat.user_name(), str) and compat.user_name()
    assert ("start_new_session" in compat.new_session_kwargs()) != compat.IS_WINDOWS


def test_local_run_shell_is_refused_on_windows(monkeypatch, tmp_path):
    from wisp import compat
    from wisp.local.tools import run_shell

    monkeypatch.setattr(compat, "IS_WINDOWS", True)
    with pytest.raises(compat.NotSupportedHere, match="Windows"):
        run_shell(tmp_path, {"command": "echo oi"})
