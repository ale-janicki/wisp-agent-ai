import os
import sys
from pathlib import Path

from wisp.cli import build_parser
from wisp.local import cli as local_cli
from wisp.local.tools import ServerSpec

HERE = Path(__file__).parent
MAIL = ServerSpec("fake-mail", sys.executable, (str(HERE / "fake_email_server.py"),), (("FAKE_MAIL_LOG", os.environ["FAKE_MAIL_LOG"]),), trusted=True)

raise SystemExit(local_cli.run(build_parser().parse_args(sys.argv[1:]), servers=[MAIL]))
