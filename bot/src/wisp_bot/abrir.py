"""Fila de topicos que o Geral pede para abrir.

O Geral e uma sessao do Claude, sem acesso ao bot: ele deixa o pedido aqui e o
bot abre o topico, posta o briefing e dispara o primeiro turno do agente de la.
Mesmo padrao do runs.py — arquivo em disco, o bot consome.

Uso (roda como script, sem depender do cwd):

  python3 -m wisp_bot.abrir --nome projeto-task-x --dir ~/repos/projeto --chat -100... <<'EOF'
  <briefing>
  EOF
"""
from __future__ import annotations
import argparse, json, os, sys, time, uuid
from pathlib import Path

from wisp_bot.config import CURRENT as _CFG

FILA = _CFG.state_dir / "abrir"


def pedir(nome: str, cwd: str, chat_id: int, briefing: str) -> Path:
    FILA.mkdir(parents=True, exist_ok=True)
    f = FILA / f"{int(time.time())}-{uuid.uuid4().hex[:6]}.json"
    tmp = f.with_suffix(".tmp")
    tmp.write_text(json.dumps({"nome": nome, "cwd": cwd, "chat_id": chat_id,
                               "briefing": briefing, "at": time.time()},
                              ensure_ascii=False), "utf-8")
    tmp.replace(f)                     # o bot nunca le um pedido pela metade
    return f


def pendentes() -> list[dict]:
    if not FILA.is_dir():
        return []
    out = []
    for f in sorted(FILA.glob("*.json")):
        try:
            d = json.loads(f.read_text("utf-8"))
        except (json.JSONDecodeError, OSError):
            f.unlink(missing_ok=True)
            continue
        d["_file"] = str(f)
        out.append(d)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="pede ao bot para abrir um topico")
    ap.add_argument("--nome", required=True)
    ap.add_argument("--dir", required=True)
    ap.add_argument("--chat", required=True, type=int)
    a = ap.parse_args()
    cwd = os.path.expanduser(a.dir)
    if not os.path.isdir(cwd):
        print(f"diretorio nao existe: {cwd}", file=sys.stderr)
        return 2
    briefing = sys.stdin.read().strip()
    if not briefing:
        print("briefing vazio: mande pelo stdin", file=sys.stderr)
        return 2
    print(f"pedido na fila: {pedir(a.nome, cwd, a.chat, briefing).name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
