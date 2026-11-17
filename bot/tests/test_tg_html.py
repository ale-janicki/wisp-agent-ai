"""Testes do tg_html: markdown do modelo vira HTML do Telegram, deterministico."""
import re


from wisp_bot import tg_html

# Respostas do assistente no formato que o modelo escreve: markdown com **negrito** e linhas "- ".
AMOSTRAS = [
    "**Resumo do snapshot**\n\nO job roda as 06h e grava o saldo do dia.\n\n"
    "- **Entrada:** `accounts` com o saldo em centavos\n- **Saida:** uma linha por conta em `snapshots`\n"
    "- Falha de rede refaz em 5 min, no maximo 3 vezes\n\nQuer que eu rode agora?",
    "Achei o problema em **dois** lugares:\n\n- o `cron` usa UTC, entao o dia vira as 21h\n"
    "- a query soma `amount` sem filtrar `deleted_at`\n\n**Proximo passo:** corrigir o filtro e testar.",
]


def _amostras() -> list[str]:
    return AMOSTRAS


def test_amostra_real_sem_markdown():
    for texto in _amostras():
        out = tg_html.sanitize(texto)
        assert "**" not in out
        assert "<b>" in out
        assert not re.search(r"^\s*- ", out, re.M)
        assert re.search(r"^\s*• ", out, re.M)
        assert all(tg_html.sanitize(p) == p for p in tg_html.split(out, 500))


def test_fence_fica_verbatim():
    out = tg_html.from_markdown("antes\n```py\nx = a**b**c\n- nao lista\n<tag>\n```\ndepois **b**")
    assert "<pre>x = a**b**c\n- nao lista\n&lt;tag&gt;</pre>" in out
    assert out.endswith("depois <b>b</b>")


def test_pre_e_code_prontos_intactos():
    src = "<pre>a**b**c\n- x</pre> e <code>_y_ **z**</code>"
    assert tg_html.sanitize(src) == src


def test_inline_code():
    assert tg_html.from_markdown("use `a<b` e **ok**") == "use <code>a&lt;b</code> e <b>ok</b>"


def test_snake_case_e_aritmetica():
    for src in ("snake_case_name e __init__x", "2*3*4 = 24", "2 * 3 * 4", "a_b_c"):
        assert tg_html.from_markdown(src) == src


def test_italico_delimitado():
    assert tg_html.from_markdown("isso *aqui* e _ali_ ok") == "isso <i>aqui</i> e <i>ali</i> ok"
    assert tg_html.from_markdown("__forte__") == "<b>forte</b>"


def test_estrutura_de_linhas():
    src = "# Titulo\n  - a\n* b\n---\n***\n| x | y |\n|---|---|\n| 1 | 2 |"
    assert tg_html.from_markdown(src) == "<b>Titulo</b>\n  • a\n• b\nx · y\n1 · 2"


def test_link_so_http():
    assert tg_html.from_markdown("[ok](https://a.com/x_y_z)") == '<a href="https://a.com/x_y_z">ok</a>'
    assert tg_html.from_markdown("[no](javascript:x)") == "[no](javascript:x)"


def test_idempotente_em_html_limpo():
    src = "<b>Oi</b> <i>x</i>\n• item\n<pre>a_b_c</pre> <a href=\"https://a.com/_q_\">l</a> &amp; <code>c</code>"
    assert tg_html.sanitize(src) == src
    assert tg_html.sanitize(tg_html.sanitize("**a** - b `c`")) == tg_html.sanitize("**a** - b `c`")


def test_split_continua_balanceado():
    texto = "```\n" + "\n".join(f"linha {i}" for i in range(400)) + "\n```"
    partes = tg_html.split(tg_html.sanitize(texto), 500)
    assert len(partes) > 1
    for p in partes:
        assert p.startswith("<pre>") and p.endswith("</pre>")
