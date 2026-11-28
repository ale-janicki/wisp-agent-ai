import os
from datetime import datetime

import pytest

from wisp.serve.store import (attachments_root, attachments_summary, parse_attachments, remove_staged, reply_split,
                              save_upload, stage_files, title_fallback, title_prompt, title_sanitize,
                              unparsed_attachments)

BLOCK = "[o usuario enviou 2 arquivo(s) pelo Wisp, ja salvos nesta maquina:\n- {a} (foto.png, 5 bytes)\n- {b} (nota (1).txt, 7 bytes)]\n\n{caption}"


def test_reply_split_strips_the_status_footer_like_the_mac():
    text = "Pronto, criei o arquivo.\n\nSTATUS · wisp · feito\nTeu: nada"
    assert reply_split(text, "STATUS ·") == ("Pronto, criei o arquivo.", "wisp · feito")
    assert reply_split(text, None) == (text, None)
    assert reply_split("sem rodape", "STATUS ·") == ("sem rodape", None)
    assert reply_split("STATUS · so isso", "STATUS ·") == ("", "so isso")


@pytest.mark.parametrize("raw,expected", [
    ('"Plano de viagem para Lisboa."', "Plano de viagem para Lisboa"),
    ("Título: **Receita de bolo**", "Receita de bolo"),
    ("\n\n  ## Boa ideia!  \nsegunda linha", "Boa ideia"),
    ("um dois tres quatro cinco seis sete oito nove", None),
    ("   \n  ", None),
    ("Palavra" * 10, None),
    ("Resumo da reunião de planejamento semanal do time", "Resumo da reunião de planejamento"),
])
def test_title_sanitize_matches_the_mac(raw, expected):
    assert title_sanitize(raw) == expected


def test_title_sanitize_cuts_at_a_word_without_the_hard_cut():
    assert title_sanitize("uma duas tres quatro cinco seis sete") == "uma duas tres quatro cinco seis sete"
    assert title_sanitize("abcdefghij klmnopqrstuvwxyz abcdefghij klmnopqrstuv") == "abcdefghij klmnopqrstuvwxyz abcdefghij"


def test_title_prompt_is_the_macs_prompt_with_the_same_cuts():
    prompt = title_prompt("u" * 2000, "r" * 900)
    assert prompt.startswith("Escreva o título de uma conversa entre um usuário e um assistente.\nRegras: 2 a 4 palavras, ")
    assert "sem emoji. Responda SOMENTE com o título.\n\nMensagem do usuário:\n" + "u" * 1500 + "\n\nInício da resposta:\n" + "r" * 800 in prompt
    assert "u" * 1501 not in prompt and "r" * 801 not in prompt


def test_title_fallback_keeps_the_word_cut():
    assert title_fallback("quero saber como funciona o cache de build do projeto") == "quero saber como funciona o"


def test_parse_attachments_reads_posix_and_windows_paths():
    text = BLOCK.format(a="/srv/anexos/wisp-ab12cd34-foto.png", b="C:\\Users\\x\\anexos\\wisp-ab12cd34-nota (1).txt",
                        caption="olha isso")
    found = parse_attachments(text)
    assert found["origin"] == "Wisp" and found["caption"] == "olha isso"
    assert found["items"][0] == {"path": "/srv/anexos/wisp-ab12cd34-foto.png", "name": "foto.png", "bytes": 5}
    assert found["items"][1]["path"] == "C:\\Users\\x\\anexos\\wisp-ab12cd34-nota (1).txt"
    assert found["items"][1]["name"] == "nota (1).txt"
    assert attachments_summary(found) == "1 foto · 1 arquivo · olha isso"


def test_parse_attachments_rejects_plain_text_and_hides_unparsed_paths():
    assert parse_attachments("[o fulano disse oi") is None
    assert parse_attachments("oi, tudo bem?") is None
    broken = "[o usuario enviou 2 arquivo(s) pelo Wisp, ja salvos nesta maquina:\n- /x/a.png (a.png, 5 bytes)]\n\nlegenda"
    assert parse_attachments(broken) is None
    assert unparsed_attachments(broken) == {"origin": "", "items": [], "caption": "legenda"}
    assert unparsed_attachments("[o fulano disse oi") is None


def test_placeholder_caption_means_no_caption():
    text = BLOCK.format(a="/a/foto.png", b="/a/b.txt", caption="(sem texto — veja o que é e me diga)")
    assert parse_attachments(text)["caption"] is None


def test_staging_copies_regular_files_into_the_day_folder_and_refuses_folders(tmp_path):
    source = tmp_path / "foto.png"
    source.write_bytes(b"12345")
    folder = tmp_path / "pasta"
    folder.mkdir()
    staged, refused, _ = stage_files([str(source), str(folder), str(tmp_path / "nao-existe.png"), "relativo.png"],
                                  tmp_path / "anexos", datetime(2026, 11, 28))
    assert len(staged) == 1 and refused == ["pasta", "nao-existe.png", "relativo.png"]
    target = staged[0]
    assert os.path.dirname(target["path"]) == os.path.realpath(tmp_path / "anexos" / "2026-11-28")
    assert os.path.basename(target["path"]).startswith("wisp-") and target["path"].endswith("-foto.png")
    assert (target["name"], target["bytes"], target["image"]) == (os.path.basename(target["path"]), 5, True)
    assert source.read_bytes() == b"12345"


def test_staging_follows_a_symlink_to_the_real_file_and_refuses_a_link_to_a_folder(tmp_path):
    real = tmp_path / "real.txt"
    real.write_text("x")
    link = tmp_path / "link.txt"
    folder = tmp_path / "pasta"
    folder.mkdir()
    pasta_link = tmp_path / "pasta-link"
    try:
        link.symlink_to(real)
        pasta_link.symlink_to(folder, target_is_directory=True)
    except OSError:
        pytest.skip("no symlinks here")
    staged, refused, _ = stage_files([str(link), str(pasta_link)], tmp_path / "anexos")
    assert len(staged) == 1 and refused == ["pasta-link"]
    assert not os.path.islink(staged[0]["path"])


def test_save_upload_names_like_the_mac_and_never_escapes_the_folder(tmp_path):
    saved = save_upload("..\\..\\evil/../colar.png", b"png", tmp_path / "anexos", datetime(2026, 1, 2))
    assert os.path.dirname(saved["path"]) == os.path.realpath(tmp_path / "anexos" / "2026-01-02")
    assert saved["path"].endswith("-colar.png") and saved["image"] is True and saved["bytes"] == 3
    blank = save_upload("  ..  ", b"x", tmp_path / "anexos")
    assert blank["path"].endswith("-arquivo")


def test_remove_staged_only_inside_the_anexos_root(tmp_path):
    root = tmp_path / "anexos"
    saved = save_upload("a.txt", b"x", root)
    outside = tmp_path / "fora.txt"
    outside.write_text("keep")
    assert remove_staged(str(outside), root) is False and outside.exists()
    assert remove_staged(str(root / ".." / "fora.txt"), root) is False and outside.exists()
    assert remove_staged(saved["path"], root) is True and not os.path.exists(saved["path"])


def test_attachments_root_prefers_the_profile_folder_then_the_wisp_folder(tmp_path):
    assert attachments_root("/srv/entrada") == __import__("pathlib").Path("/srv/entrada")
    assert attachments_root(None, env={"WISP_DATA_DIR": str(tmp_path)}) == tmp_path / "anexos"


def test_staging_refuses_a_file_over_the_upload_limit(tmp_path):
    big = tmp_path / "grande.bin"
    big.write_bytes(b"x" * 11)
    small = tmp_path / "pequeno.txt"
    small.write_text("ok")
    staged, refused, too_big = stage_files([str(big), str(small)], tmp_path / "anexos", limit=10)
    assert [f["name"].endswith("pequeno.txt") for f in staged] == [True]
    assert (refused, too_big) == ([], ["grande.bin"])
    assert not any("grande" in p.name for p in (tmp_path / "anexos").rglob("*"))


def test_only_files_this_api_staged_can_be_removed_even_inside_the_folder(tmp_path):
    root = tmp_path / "anexos"
    source = tmp_path / "a.txt"
    source.write_text("x")
    staged = stage_files([str(source)], root)[0][0]["path"]
    uploaded = save_upload("b.txt", b"y", root)["path"]
    stranger = root / "2026-01-01" / "wisp-deadbeef-dela.txt"
    stranger.parent.mkdir(parents=True)
    stranger.write_text("not ours")
    assert remove_staged(str(stranger), root) is False and stranger.exists()
    assert remove_staged(staged, root) is True and remove_staged(uploaded, root) is True
    assert remove_staged(staged, root) is False, "already gone and no longer registered"
    again = tmp_path / "again"
    other_root = tmp_path / "outro"
    assert remove_staged(str(again), other_root) is False
