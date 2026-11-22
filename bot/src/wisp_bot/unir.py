from __future__ import annotations
import hashlib, json, logging, shutil, time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from . import compartilhar, sessao
from .store import file_lock
from .transcript import Transcripts, VERSION, coverage, encode, read_entries, stamp

log = logging.getLogger("wisp.unir")

_BACKUPS = "backup-conversas"


@dataclass
class Grupo:
    sobrevivente: dict
    perdedores: list[dict]
    topicos: list[str]
    sessoes: list[str]
    arquivos: list[str]
    importar: list[str]
    conversa: str
    nao_importaveis: list[str] = field(default_factory=list)
    mantidos: list[dict] = field(default_factory=list)
    motivos: list[str] = field(default_factory=list)
    recusado: bool = False

    @property
    def topico(self) -> str | None:
        return self.topicos[0] if self.topicos else None


class PlanoMudou(RuntimeError):
    pass


def _ligados(record: dict, topicos: dict[str, dict], transcripts: Transcripts) -> set[str]:
    sid = record.get("sessionId")
    out = set()
    for k, t in topicos.items():
        conv = str(t.get("conversation") or "")
        if (sid and sid == t.get("session_id")) or (conv and conv == _id(record)) \
                or (sid and conv and transcripts.find(sid) == conv):
            out.add(k)
    return out


def _id(record: dict) -> str:
    return str(record.get("id") or "").lower()


def _atualizado(record: dict) -> str:
    return str(record.get("updatedAt") or "")


def _raiz(pai: dict, x):
    while pai[x] != x:
        pai[x] = pai[pai[x]]
        x = pai[x]
    return x


def _pendente(record: dict, transcripts: Transcripts) -> bool:
    sid = record.get("sessionId")
    stem = transcripts.find(sid) if sid else None
    if not stem or sessao.achar_local(sid) is not None:
        return False
    return any(e.get("kind") == "session" and e.get("session") == sid and e.get("reason") == "pending-import"
               for e in read_entries(transcripts.path(stem)))


def plano(records: list[dict], topicos: dict[str, dict], transcripts: Transcripts) -> list[Grupo]:
    records = [r for r in records if not _pendente(r, transcripts)]
    pai = {("r", _id(r)): ("r", _id(r)) for r in records}
    pai.update({("t", k): ("t", k) for k in topicos})
    motivo: dict = {}

    def unir(a, b, why: str) -> None:
        if a not in pai or b not in pai:
            return
        ra, rb = _raiz(pai, a), _raiz(pai, b)
        if ra != rb:
            pai[ra] = rb
        motivo.setdefault(_raiz(pai, a), []).append(why)

    por_arquivo: dict[str, tuple] = {}
    for r in records:
        sid = r.get("sessionId")
        stem = transcripts.find(sid) if sid else None
        stem = stem or (_id(r) if transcripts.path(_id(r)).exists() else None)
        if stem:
            if stem in por_arquivo:
                unir(("r", _id(r)), por_arquivo[stem], f"mesmo arquivo de conversa {stem}")
            else:
                por_arquivo[stem] = ("r", _id(r))
            dono = next((x for x in records if _id(x) == stem), None)
            if dono is not None:
                unir(("r", _id(r)), ("r", stem), f"arquivo de conversa {stem}")
    ligados = {_id(r): _ligados(r, topicos, transcripts) for r in records}
    for k, t in topicos.items():
        for r in records:
            if k in ligados[_id(r)]:
                unir(("t", k), ("r", _id(r)), "sessão atual do tópico")
        if k.rsplit(":", 1)[-1] == "0":
            for r in records:
                if str(r.get("title") or "") == str(t.get("name") or "Geral") and ligados[_id(r)] <= {k}:
                    unir(("t", k), ("r", _id(r)), "Geral é uma conversa só")

    grupos: dict = {}
    for no in pai:
        grupos.setdefault(_raiz(pai, no), []).append(no)
    saida: list[Grupo] = []
    for raiz, nos in grupos.items():
        recs = [r for r in records if ("r", _id(r)) in nos]
        tops = [k for kind, k in nos if kind == "t"]
        if not recs:
            continue
        if len(tops) > 1:
            saida.append(Grupo(max(recs, key=_atualizado), [], sorted(tops), [], [], [], "", [], [],
                               motivo.get(_raiz(pai, nos[0]), []), True))
            continue
        topico = tops[0] if tops else None
        ligado = [r for r in recs if topico and (r.get("sessionId") == topicos[topico].get("session_id")
                                                  or _id(r) == str(topicos[topico].get("conversation") or ""))]
        base = ligado or recs
        vencedor = max(base, key=_atualizado)
        perdedores = [r for r in recs if r is not vencedor]
        conversa = _id(vencedor)
        precisa_topico = bool(topico) and str(topicos[topico].get("conversation") or "") != conversa
        if not perdedores and not precisa_topico:
            continue
        sessoes: list[str] = []
        for r in sorted(recs, key=_atualizado):
            if r.get("sessionId") and r["sessionId"] not in sessoes:
                sessoes.append(r["sessionId"])
        if topico and topicos[topico].get("session_id") and topicos[topico]["session_id"] not in sessoes:
            sessoes.append(topicos[topico]["session_id"])
        arquivos = sorted({s for s in (transcripts.find(x) for x in sessoes) if s}
                          | {_id(r) for r in recs if transcripts.path(_id(r)).exists()}
                          | ({str(topicos[topico].get("conversation"))}
                             if topico and topicos[topico].get("conversation")
                             and transcripts.path(str(topicos[topico]["conversation"])).exists() else set()))
        cobertas = {s for arquivo in arquivos for s, n in coverage(read_entries(transcripts.path(arquivo))).items() if n}
        faltam = [s for s in sessoes if perdedores and s not in cobertas and sessao.valido(s)]
        importar = [s for s in faltam if sessao.achar_local(s) is not None]
        nao_importaveis = [s for s in faltam if s not in importar]
        mantidos = [r for r in perdedores if r.get("sessionId") in nao_importaveis]
        saida.append(Grupo(vencedor, perdedores, tops, sessoes, arquivos, importar, conversa,
                           nao_importaveis, mantidos, motivo.get(_raiz(pai, nos[0]), [])))
    return saida


def importar_sessao(session_id: str) -> list[dict]:
    arquivo = sessao.achar_local(session_id)
    if arquivo is None:
        return []
    out = []
    for linha in arquivo.read_text("utf-8", errors="replace").splitlines():
        try:
            o = json.loads(linha)
        except ValueError:
            continue
        msg = o.get("message") if isinstance(o, dict) else None
        if not isinstance(msg, dict) or o.get("isMeta") or o.get("isSidechain") or o.get("type") not in ("user", "assistant"):
            continue
        texto = compartilhar._texto(msg.get("content"))
        if not texto or texto.startswith(compartilhar._WRAPPERS):
            continue
        quando = compartilhar._data(o.get("timestamp"))
        at = stamp(datetime.fromtimestamp(quando).astimezone()) if quando else ""
        entry = {"v": VERSION, "at": at, "kind": o["type"], "surface": "import", "text": texto}
        if o["type"] == "assistant":
            entry.update(engine="claude", model=str(msg.get("model") or ""))
        out.append(entry)
    return out


def montar(grupo: Grupo, transcripts: Transcripts) -> list[dict]:
    entradas: list[dict] = []
    for arquivo in grupo.arquivos:
        entradas += read_entries(transcripts.path(arquivo))
    for sid in grupo.importar:
        entradas += importar_sessao(sid)
    vistos: set[str] = set()
    unicas = []
    for e in entradas:
        chave = encode(e)
        if chave not in vistos:
            vistos.add(chave)
            unicas.append(e)
    unicas.sort(key=lambda e: str(e.get("at") or ""))
    ligadas = {e.get("session") for e in unicas if e.get("kind") == "session"}
    inicio = unicas[0]["at"] if unicas and unicas[0].get("at") else stamp()
    novas = [{"v": VERSION, "at": inicio, "kind": "session", "session": s, "engine": "claude",
              "reason": "pending-import" if s in grupo.nao_importaveis else "merged"}
             for s in grupo.sessoes if s not in ligadas]
    return novas + unicas


def descrever(grupos: list[Grupo], topicos: dict[str, dict], transcripts: Transcripts) -> list[str]:
    linhas = []
    for g in grupos:
        v = g.sobrevivente
        if g.recusado:
            linhas.append(f"recusado: o grupo toca mais de um tópico ({', '.join(g.topicos)}) e o registro "
                          f"{_id(v)} «{v.get('title')}»; nada será feito com ele")
            continue
        linhas.append(f"conversa {g.conversa} «{v.get('title')}» (sessão {str(v.get('sessionId') or '-')[:8]}, "
                      f"atualizada {v.get('updatedAt')})")
        for r in g.perdedores:
            acao = "junta e mantém no índice (histórico não importável)" if r in g.mantidos else "junta e remove do índice"
            linhas.append(f"  {acao}: {_id(r)} «{r.get('title')}» "
                          f"(sessão {str(r.get('sessionId') or '-')[:8]}, atualizada {r.get('updatedAt')})")
        if g.topico:
            t = topicos[g.topico]
            linhas.append(f"  tópico {g.topico} «{t.get('name')}»: conversation "
                          f"{(str(t.get('conversation') or '') or '(vazia)')} -> {g.conversa}")
        linhas.append(f"  sessões ligadas: {', '.join(s[:8] for s in g.sessoes) or '-'}")
        linhas.append(f"  arquivos de conversa a juntar: {', '.join(g.arquivos) or 'nenhum'}")
        if g.importar:
            n = {s: len(importar_sessao(s)) for s in g.importar}
            linhas.append("  histórico a importar das sessões do Claude: "
                          + ", ".join(f"{s[:8]} ({c} mensagens)" for s, c in n.items()))
        for sid in g.nao_importaveis:
            linhas.append(f"  sessão {sid[:8]} não importável: o arquivo do Claude não está neste Mac "
                          "(pode ter rodado em outra máquina); ela fica ligada à conversa e entra quando o arquivo aparecer")
        linhas.append(f"  por quê: {'; '.join(dict.fromkeys(g.motivos)) or '-'}")
    return linhas


def _gravar(path: Path, texto: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(texto, "utf-8")
    tmp.chmod(0o600)
    tmp.replace(path)


def assinatura(grupos: list[Grupo], transcripts: Transcripts) -> list:
    def tamanho(arquivo: str) -> int:
        try:
            return transcripts.path(arquivo).stat().st_size
        except OSError:
            return -1
    return sorted([g.conversa, sorted(_id(r) for r in g.perdedores), list(g.topicos), list(g.sessoes),
                   [[a, tamanho(a)] for a in g.arquivos], list(g.importar), list(g.nao_importaveis), g.recusado]
                  for g in grupos)


def plano_id(grupos: list[Grupo], transcripts: Transcripts) -> str:
    corpo = json.dumps(assinatura(grupos, transcripts), sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(corpo.encode("utf-8")).hexdigest()[:12]


def aplicar(grupos: list[Grupo], indice: Path, store_path: Path, transcripts: Transcripts, wisp_dir: Path,
            agora: float | None = None) -> Path | None:
    with file_lock(store_path):
        records = json.loads(indice.read_text("utf-8"))
        topicos = json.loads(store_path.read_text("utf-8")) if store_path.exists() else {}
        transcripts.found.clear()
        atual = plano(records, topicos, transcripts)
        if plano_id(atual, transcripts) != plano_id(grupos, transcripts):
            raise PlanoMudou("os dados mudaram desde o plano; rode o plano de novo")
        acionaveis = [g for g in atual if not g.recusado]
        if not acionaveis:
            return None
        return _aplicar(acionaveis, records, topicos, indice, store_path, transcripts,
                        wisp_dir, agora)


def _aplicar(grupos: list[Grupo], records: list[dict], topicos: dict, indice: Path, store_path: Path,
             transcripts: Transcripts, wisp_dir: Path, agora: float | None) -> Path:
    agora = time.time() if agora is None else agora
    trabalho = [(g, montar(g, transcripts)) for g in grupos]
    remover: set[str] = set()
    apagar: list[str] = []
    log_linhas = []
    for g, entradas in trabalho:
        vivo = next(r for r in records if str(r.get("id") or "").lower() == g.conversa)
        for r in g.perdedores:
            if r in g.mantidos:
                continue
            remover.add(_id(r))
            if _atualizado(r) > _atualizado(vivo):
                vivo.update({k: r[k] for k in ("updatedAt", "lastPreview", "lastFrom") if r.get(k) is not None})
        for k in g.topicos:
            if k not in topicos:
                continue
            topicos[k]["conversation"] = g.conversa
            vivo["sessionId"] = topicos[k].get("session_id") or vivo.get("sessionId")
            topicos[k].setdefault("meta", {}).setdefault("espelhado_ate", stamp())
        apagar += [a for a in g.arquivos if a != g.conversa]
        log_linhas.append(f"{g.conversa}: {len(g.perdedores)} conversa(s) juntada(s), {len(entradas)} linhas no arquivo, "
                          f"tópico {', '.join(g.topicos) or '-'}")
    novos = [r for r in records if str(r.get("id") or "").lower() not in remover]
    pasta = wisp_dir / _BACKUPS / time.strftime("%Y%m%d-%H%M%S", time.localtime(agora))
    pasta.mkdir(parents=True, exist_ok=True)
    for origem in (indice, store_path):
        if origem.exists():
            shutil.copy2(origem, pasta / origem.name)
    for g in grupos:
        for arquivo in g.arquivos:
            origem = transcripts.path(arquivo)
            if origem.exists():
                shutil.copy2(origem, pasta / f"conversa-{origem.name}")
    for g, entradas in trabalho:
        if entradas and (g.perdedores or g.arquivos):
            _gravar(transcripts.path(g.conversa), "".join(encode(e) + "\n" for e in entradas))
    _gravar(indice, json.dumps(novos, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    if topicos:
        _gravar(store_path, json.dumps(topicos, indent=2, ensure_ascii=False))
    for arquivo in apagar:
        transcripts.path(arquivo).unlink(missing_ok=True)
    transcripts.found.clear()
    with (pasta / "unir.log").open("a", encoding="utf-8") as f:
        for linha in log_linhas:
            f.write(f"{stamp()} {linha}\n")
    for linha in log_linhas:
        log.info("unir: %s", linha)
    return pasta
