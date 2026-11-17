import os

from wisp.runner import SubprocessRunner


def test_killpg_tolerates_child_already_gone(monkeypatch):
    real = os.killpg

    def killpg_after_exit(pid, sig):
        real(pid, sig)
        raise ProcessLookupError

    monkeypatch.setattr(os, "killpg", killpg_after_exit)
    result = SubprocessRunner().run(["sleep", "5"], timeout=0.2)
    assert result.timed_out
