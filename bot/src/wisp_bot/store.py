"""Mapa topico -> sessao. Sobrevive a restart do servico."""
from __future__ import annotations
import json, threading, time, uuid
from dataclasses import dataclass, asdict, field
from pathlib import Path

from .config import CURRENT as _CFG

STORE = _CFG.state_dir / "topics.json"


@dataclass
class Topic:
    key: str                  # "<chat_id>:<thread_id>"; thread 0 = Geral
    name: str
    session_id: str
    cwd: str
    started: bool = False     # False = ainda nao existe sessao; usa --session-id
    turns: int = 0            # turnos desta sessao; o custo sobe com eles
    cost: float = 0.0         # US$ acumulados NESTA sessao (zera no reset)
    last_used: float = 0.0    # epoch do ultimo turno
    born: float = 0.0         # epoch do 1o turno desta sessao; o Geral recicla por idade
    meta: dict = field(default_factory=dict)


class Store:
    """Persistencia simples com lock. O volume aqui e de dezenas de itens, nao milhares."""

    def __init__(self, path: Path = STORE):
        self.path = path
        self._lock = threading.Lock()
        self._data: dict[str, Topic] = {}
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            raw = json.loads(self.path.read_text("utf-8"))
        except (json.JSONDecodeError, OSError):
            # arquivo corrompido nao pode derrubar o bot: comeca limpo e segue
            return
        self._data = {k: Topic(**v) for k, v in raw.items()}

    def _flush(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps({k: asdict(v) for k, v in self._data.items()},
                                  indent=2, ensure_ascii=False), "utf-8")
        tmp.replace(self.path)          # troca atomica: nunca deixa json pela metade

    def get_or_create(self, key: str, name: str, cwd: str, meta: dict | None = None) -> Topic:
        with self._lock:
            t = self._data.get(key)
            if t is None:
                m = dict(meta or {})
                m.setdefault("criado", time.time())     # quando o topico nasceu
                t = Topic(key=key, name=name, session_id=str(uuid.uuid4()), cwd=cwd,
                          meta=m)                       # nasce ja marcado: um crash nao deixa espelho sem marca
                self._data[key] = t
                self._flush()
            return t

    def renomear(self, key: str, name: str) -> bool:
        """Troca o nome do registro (so o nome: sessao, cwd e meta ficam). Topico inexistente: False."""
        with self._lock:
            t = self._data.get(key)
            if t is None:
                return False
            if t.name != name:
                t.name = name
                self._flush()
            return True

    def set_meta(self, key: str, **campos) -> None:
        """Grava campos em meta num flush so; valor None apaga a chave. Topico inexistente: ignora."""
        with self._lock:
            t = self._data.get(key)
            if t is None:
                return
            for k, v in campos.items():
                if v is None:
                    t.meta.pop(k, None)
                else:
                    t.meta[k] = v
            self._flush()

    def get(self, key: str) -> Topic | None:
        with self._lock:
            return self._data.get(key)

    def mark_started(self, key: str) -> None:
        with self._lock:
            if key in self._data and not self._data[key].started:
                self._data[key].started = True
                self._flush()

    def bump(self, key: str, cost: float | None) -> None:
        """Contabiliza um turno. E isto que alimenta o reset automatico."""
        with self._lock:
            t = self._data.get(key)
            if t is None:
                return
            t.turns += 1
            t.cost += float(cost or 0.0)
            t.last_used = time.time()
            if not t.born:
                t.born = t.last_used
            self._flush()

    def set_cwd(self, key: str, cwd: str) -> None:
        with self._lock:
            if key in self._data:
                self._data[key].cwd = cwd
                self._flush()

    def reset(self, key: str) -> None:
        """Nova sessao no mesmo topico, mantendo nome e cwd."""
        with self._lock:
            if key in self._data:
                self._data[key].session_id = str(uuid.uuid4())
                self._data[key].started = False
                self._data[key].turns = 0
                self._data[key].cost = 0.0
                self._data[key].born = 0.0
                # o ponteiro de sessao vence pelo mais recente: o reset tem que ser o mais novo
                self._data[key].last_used = time.time()
                self._flush()

    def adotar_sessao(self, key: str, session_id: str) -> None:
        """Aponta o topico para uma sessao que ja existe (veio do terminal).
        turns >= 1 porque o encerrar so grava o resumo no brain de sessao com turnos."""
        with self._lock:
            t = self._data.get(key)
            if t:
                t.session_id = session_id
                t.started = True
                t.turns = max(t.turns, 1)
                self._flush()

    def seguir_sessao(self, key: str, session_id: str, started: bool,
                      born: float = 0.0, last_used: float = 0.0) -> None:
        """A nota do brain manda: este topico passa a usar a sessao que ela aponta, com a
        idade (born) que ela tinha, para o reset de 24h do Geral continuar valendo."""
        with self._lock:
            t = self._data.get(key)
            if t:
                t.session_id = session_id
                t.started = started
                t.turns = max(t.turns, 1) if started else 0
                t.born = born if started else 0.0
                t.last_used = last_used or t.last_used
                self._flush()

    def drop(self, key: str) -> Topic | None:
        """Solta o topico. A sessao do Claude nao e apagada em disco — ela so deixa
        de ser referenciada, entao nada que ja virou nota no brain se perde."""
        with self._lock:
            t = self._data.pop(key, None)
            if t:
                self._flush()
            return t

    def all(self) -> list[Topic]:
        with self._lock:
            return list(self._data.values())
