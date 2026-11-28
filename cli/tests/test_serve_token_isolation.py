import os
import subprocess
import sys

from wisp.serve import claude_session
from wisp.serve import __main__ as serve_main


def test_the_agent_never_inherits_the_sidecar_token(monkeypatch):
    monkeypatch.setenv("WISP_SERVE_TOKEN", "secret-token")
    env = claude_session.child_environment(sys.executable)
    assert "WISP_SERVE_TOKEN" not in env


def test_the_sidecar_removes_the_token_from_its_own_environment_at_start(monkeypatch):
    monkeypatch.setenv("WISP_SERVE_TOKEN", "secret-token")
    seen = {}

    class StopHere(Exception):
        pass

    def fake_create_app(token):
        seen["token"] = token
        seen["env_has_token"] = "WISP_SERVE_TOKEN" in os.environ
        raise StopHere

    monkeypatch.setattr(serve_main, "create_app", fake_create_app)
    try:
        serve_main.main([])
    except StopHere:
        pass
    assert seen == {"token": "secret-token", "env_has_token": False}


def test_any_child_the_sidecar_starts_has_no_token(monkeypatch):
    monkeypatch.setenv("WISP_SERVE_TOKEN", "secret-token")
    serve_main.take_token()
    out = subprocess.run([sys.executable, "-c", "import os; print(os.environ.get('WISP_SERVE_TOKEN', 'absent'))"],
                         capture_output=True, text=True).stdout.strip()
    assert out == "absent"
