import json
import os
import tempfile
from pathlib import Path

# Runs at collection, before any test module imports wisp_bot: the module constants
# resolve under this throwaway HOME and this config, never the real ones. The copied
# suite exercises the Mac<->PC code, so the default test config is `pair`.
_HOME = Path(tempfile.mkdtemp(prefix="wisp-bot-home-"))
os.environ["HOME"] = str(_HOME)
for _k in [k for k in os.environ if k.startswith("WISP_")]:
    del os.environ[_k]
_CONFIG = _HOME / ".config/wisp/wisp.json"
_CONFIG.parent.mkdir(parents=True)
(_HOME / "token").write_text("0:test\n")
_CONFIG.write_text(json.dumps({
    "brain": str(_HOME / "brain"),
    "telegram": {
        "chat_id": -1001, "user_id": 1, "token_file": str(_HOME / "token"),
        "state_dir": str(_HOME / ".local/state/wisp/bot"), "hosting": "pair",
        "pair": {"pc_name": "pc-node", "user": "pc-user", "config": str(_HOME / ".config/pair/config")},
    },
}))
os.environ["WISP_CONFIG"] = str(_CONFIG)
