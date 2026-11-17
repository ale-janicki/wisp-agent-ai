"""HTML do Telegram que nunca chega quebrado ao usuario.

O modelo escreve o HTML da resposta, e as vezes erra: tag desconhecida (medido
30/09: um `</parameter>` de chamada de ferramenta vazou no texto), tag sem
fechar, `<` solto. O Telegram recusa a mensagem inteira, e o fallback antigo
reenviava o texto com html.escape — o usuario via `&lt;b&gt;` literal.

Tambem o corte em pedacos de 4000: um <pre> que atravessa o corte deixava os
dois pedacos invalidos. Aqui cada pedaco fecha o que abriu e o seguinte reabre.
"""
from __future__ import annotations
import html, re

ALLOWED = {"b", "strong", "i", "em", "u", "ins", "s", "strike", "del",
           "code", "pre", "a", "tg-spoiler", "blockquote", "span"}
_TAG = re.compile(r"<(/?)([a-zA-Z][\w-]*)((?:\s[^<>]*)?)>")
_ENTITY = re.compile(r"&(?:[a-zA-Z]+|#\d+|#x[0-9a-fA-F]+);")

# markdown -> HTML (tamanhos limitados: sem teto, um ** sem par varre o texto todo)
# o que fica verbatim (cerca, <pre>/<code> prontos, `inline`, tags)
_FENCE = re.compile(r"```[^\n]*\n(.*?)```", re.S)
_VERBATIM = re.compile(r"<(pre|code)\b[^>]*>.*?</\1>|`([^`\n]+)`|</?[a-zA-Z][^<>]*>", re.S | re.I)
_LINK = re.compile(r"\[([^\]\n]{1,300})\]\((https?://[^\s)]{1,2000})\)")
_BOLD = re.compile(r"(?<![\w*])\*\*(?=\S)([^\n]{1,500}?)(?<=\S)\*\*(?![\w*])|(?<![\w])__(?=\S)([^\n]{1,500}?)(?<=\S)__(?![\w])")
_ITAL_STAR = re.compile(r"(?<![\w*])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?![\w*])")
_ITAL_UND = re.compile(r"(?<![\w])_(?=[^\s_])([^_\n]+?)(?<=[^\s_])_(?![\w])")
_HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$")
_HRULE = re.compile(r"^\s*([-*_])(?:\s*\1){2,}\s*$")
_BULLET = re.compile(r"^(\s*)[-*]\s+")
_TABLE_SEP = re.compile(r"^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)*\|?\s*$")
_TABLE_ROW = re.compile(r"^\s*\|(.+)\|\s*$")
_SLOT = re.compile(r"\x00(\d+)\x00")


def _tokens(text: str):
    """[(kind, value, name, is_close)] — kind 'tag' ou 'text'."""
    pos = 0
    for m in _TAG.finditer(text):
        if m.start() > pos:
            yield ("text", text[pos:m.start()], None, False)
        yield ("tag", m.group(0), m.group(2).lower(), m.group(1) == "/")
        pos = m.end()
    if pos < len(text):
        yield ("text", text[pos:], None, False)


def _escape_loose(s: str) -> str:
    """Escapa '<' e '>' soltos e '&' que nao inicia entidade; mantem entidades."""
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "&":
            m = _ENTITY.match(s, i)
            if m:
                out.append(m.group(0)); i = m.end(); continue
            out.append("&amp;")
        elif c == "<":
            out.append("&lt;")
        elif c == ">":
            out.append("&gt;")
        else:
            out.append(c)
        i += 1
    return "".join(out)


def _md_line(line: str) -> str | None:
    """Estrutura de uma linha (titulo, lista, tabela). None = linha removida."""
    if _HRULE.match(line) or ("|" in line and _TABLE_SEP.match(line)):
        return None
    m = _HEADING.match(line)
    if m:
        return f"<b>{m.group(1)}</b>"
    m = _TABLE_ROW.match(line)
    if m:
        return " · ".join(c.strip() for c in m.group(1).split("|"))
    return _BULLET.sub(r"\1• ", line)


def from_markdown(text: str) -> str:
    """Markdown do modelo -> HTML do Telegram. Codigo e tags prontas passam
    verbatim; HTML ja correto sem markdown sai igual."""
    slots: list[str] = []

    def stash(html_: str) -> str:
        slots.append(html_)
        return f"\x00{len(slots) - 1}\x00"

    def verbatim(m: re.Match) -> str:
        if m.group(2) is not None:
            return stash(f"<code>{html.escape(m.group(2), quote=False)}</code>")
        return stash(m.group(0))

    text = _FENCE.sub(lambda m: stash(f"<pre>{html.escape(m.group(1).rstrip(chr(10)), quote=False)}</pre>"), text)
    text = _VERBATIM.sub(verbatim, text)
    text = _LINK.sub(lambda m: stash(f'<a href="{html.escape(m.group(2))}">{m.group(1)}</a>'), text)
    lines = (_md_line(ln) for ln in text.split("\n"))
    text = "\n".join(ln for ln in lines if ln is not None)
    text = _BOLD.sub(lambda m: f"<b>{m.group(1) or m.group(2)}</b>", text)
    text = _ITAL_UND.sub(r"<i>\1</i>", _ITAL_STAR.sub(r"<i>\1</i>", text))
    return _SLOT.sub(lambda m: slots[int(m.group(1))], text)


def sanitize(text: str) -> str:
    """So tags permitidas, balanceadas; o resto vira texto seguro."""
    text = from_markdown(text)
    out, stack = [], []           # stack: [(name, raw_open_tag)]
    for kind, val, name, close in _tokens(text):
        if kind == "text":
            out.append(_escape_loose(val))
            continue
        if name not in ALLOWED:
            continue              # tag desconhecida: some (nao vira texto)
        if not close:
            stack.append((name, val))
            out.append(val)
        elif any(n == name for n, _ in stack):
            while stack:          # fecha o que ficou aberto dentro dela
                n, _ = stack.pop()
                out.append(f"</{n}>")
                if n == name:
                    break
        # fechamento sem abertura: descarta
    while stack:
        out.append(f"</{stack.pop()[0]}>")
    return "".join(out)


def split(text: str, size: int = 4000) -> list[str]:
    """Pedacos <= size (aprox.), cortados em quebra de linha, cada um com as
    tags balanceadas: fecha no fim o que estava aberto e reabre no seguinte."""
    lines = text.split("\n")
    parts, cur, stack = [], "", []

    def open_prefix():
        return "".join(raw for _, raw in stack)

    def close_suffix():
        return "".join(f"</{n}>" for n, _ in reversed(stack))

    for line in lines:
        piece = line if not cur else "\n" + line
        if cur and len(cur) + len(piece) + len(close_suffix()) > size:
            parts.append(cur + close_suffix())
            cur = open_prefix() + line
        else:
            cur += piece
        for kind, val, name, close in _tokens(line):
            if kind == "tag" and name in ALLOWED:
                if not close:
                    stack.append((name, val))
                elif stack and stack[-1][0] == name:
                    stack.pop()
    if cur:
        parts.append(cur)
    # linha unica maior que o limite: corte bruto, ainda balanceado por sanitize
    out = []
    for p in parts:
        while len(p) > size:
            out.append(sanitize(p[:size])); p = p[size:]
        out.append(sanitize(p) if p else p)
    return [p for p in out if p.strip()]


def plain(text: str) -> str:
    """Texto limpo para o ultimo recurso: sem tags e sem entidades escapadas."""
    return html.unescape(_TAG.sub("", text))
