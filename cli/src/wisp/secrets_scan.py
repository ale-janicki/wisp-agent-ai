import re
import sys
from collections.abc import Iterable
from pathlib import Path

SECRETS = re.compile(r'(sk-ant-[a-zA-Z0-9][a-zA-Z0-9-]{5,}|sk-proj-[a-zA-Z0-9][a-zA-Z0-9-]{5,}|sk-[a-zA-Z0-9]{20,}|AKIA[A-Z0-9]{16}|xox[bp]-[a-zA-Z0-9][a-zA-Z0-9-]{5,}|gh[po]_[a-zA-Z0-9]{36}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|sbp_[a-f0-9]{40}|github_pat_[A-Za-z0-9_]{22,}|[sr]k_live_[A-Za-z0-9]{10,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|phc_[A-Za-z0-9]{30,}|[0-9]{8,10}:[A-Za-z0-9_-]{35})')
SECRETS_ALLOW = re.compile(r'^(AKIAIOSFODNN7EXAMPLE|AKIAI44QH8DHBEXAMPLE)$')
BINARY_PROBE = 8192


def _redact(match: str) -> str:
    return match[:6] + "…"


def scan_text(text: str) -> list[str]:
    return [_redact(m.group(0)) for m in SECRETS.finditer(text) if not SECRETS_ALLOW.match(m.group(0))]


def scan_paths(paths: Iterable[Path]) -> dict[Path, list[str]]:
    found: dict[Path, list[str]] = {}
    for path in paths:
        try:
            raw = path.read_bytes()
        except OSError:
            found[path] = ["unreadable"]
            continue
        if b"\x00" in raw[:BINARY_PROBE]:
            continue
        hits = scan_text(raw.decode(errors="replace"))
        if hits:
            found[path] = hits
    return found


def _walk(roots: Iterable[Path]) -> Iterable[Path]:
    skip = {".venv", "__pycache__", ".git", ".pytest_cache"}
    for root in roots:
        if root.is_file() or root.is_symlink():
            yield root
        else:
            yield from (p for p in sorted(root.rglob("*")) if (p.is_file() or p.is_symlink()) and not skip & set(p.parts))


def main(argv: list[str]) -> int:
    found = scan_paths(_walk(Path(a) for a in argv))
    for path, hits in found.items():
        for hit in hits:
            print(f"{path}: {hit}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
