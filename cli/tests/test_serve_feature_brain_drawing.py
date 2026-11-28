import json
from pathlib import Path

import pytest

from wisp.serve.features.brain import drawing, lzstring

FIXTURE = Path(__file__).resolve().parents[2] / "core/Tests/WispCoreTests/Fixtures/drawings/neutral-compressed.excalidraw.md"

VECTORS = [
    ("Hello World", "BIUwNmD2AEDqkCcwBMg="),
    ("a", "IZA="),
    ("aaaaaaaaaaaaaaaa", "IY1/EA=="),
    ("Olá, mundo — ação ✓ 😀", "PIGwhwNABAtgrgOwCYHsqBQCKBDA5wY7UGRyKQXg3AAPaA=="),
    ('{"a":[1,2,3]}', "N4IghiBcDaCMA0AmeBmAugXyA==="),
    ("abababababababababab", "IYI17SIo"),
    ("", "Q==="),
]


@pytest.mark.parametrize("text,packed", VECTORS)
def test_lzstring_matches_the_reference_library(text, packed):
    assert lzstring.compress_to_base64(text) == packed
    if text:
        assert lzstring.decompress_from_base64(packed) == text


def test_lzstring_round_trip_of_long_varied_text():
    text = "".join(chr(0x41 + (i * 7) % 26) + ("é" if i % 5 == 0 else "😀" if i % 11 == 0 else " ") for i in range(6000))
    assert lzstring.decompress_from_base64(lzstring.compress_to_base64(text)) == text
    assert lzstring.decompress_from_base64("") is None


def test_reads_the_real_compressed_excalidraw_file():
    file = drawing.parse_excalidraw(FIXTURE.read_text(encoding="utf-8"), "n.excalidraw.md")
    scene = file.scene
    assert scene["type"] == "excalidraw" and isinstance(scene["elements"], list) and scene["elements"]
    assert file.encoding == "compressed" and file.container == "markdown"


def test_saving_a_scene_keeps_the_plugin_sections_and_trailer():
    text = FIXTURE.read_text(encoding="utf-8")
    file = drawing.parse_excalidraw(text, "n.excalidraw.md")
    again = drawing.parse_excalidraw(file.serialized(), "n.excalidraw.md")
    assert again.scene == file.scene
    out = file.serialized()
    assert "Texto livre antes dos dados, preservado." in out and "## Embedded Files" in out and "## Element Links" in out
    scene = json.loads(json.dumps(file.scene))
    scene["elements"].append({"id": "novo1234", "type": "text", "text": "Ola nova", "originalText": "Ola nova", "isDeleted": False})
    file.set_scene(scene)
    saved = drawing.parse_excalidraw(file.serialized(), "n.excalidraw.md")
    assert any(e["id"] == "novo1234" for e in saved.scene["elements"])
    assert "Ola nova ^novo1234" in file.serialized()


def test_plain_excalidraw_json_round_trip_keeps_indent():
    raw = json.dumps({"type": "excalidraw", "version": 2, "elements": [], "appState": {}, "files": {}}, indent="  ") + "\n"
    file = drawing.parse_excalidraw(raw, "x.excalidraw")
    assert file.container == "plain" and file.serialized() == raw


def test_blank_drawing_parses_back_and_has_the_plugin_header():
    blank = drawing.blank_excalidraw()
    assert blank.startswith("---\n\nexcalidraw-plugin: parsed\n")
    assert drawing.parse_excalidraw(blank, "n.excalidraw.md").scene["elements"] == []


def test_invalid_drawing_is_an_error_not_a_crash():
    with pytest.raises(drawing.DrawingError):
        drawing.parse_excalidraw("# nada\n", "n.excalidraw.md")


def test_canvas_round_trip_and_validation():
    blank = drawing.blank_canvas()
    assert json.loads(blank) == {"nodes": [], "edges": []}
    parsed = drawing.parse_canvas('{"nodes":[{"id":"a","type":"text","text":"oi","x":0,"y":0,"width":10,"height":10}],"edges":[]}')
    assert parsed["nodes"][0]["text"] == "oi"
    with pytest.raises(drawing.DrawingError):
        drawing.parse_canvas("[1,2]")


def test_kind_of_path():
    assert drawing.kind_of("a/b.excalidraw.md") == "excalidraw"
    assert drawing.kind_of("a/b.excalidraw") == "excalidraw"
    assert drawing.kind_of("a/b.canvas") == "canvas"
    assert drawing.kind_of("a/b.md") is None
