from __future__ import annotations

import base64
import json
import mimetypes
import re
from dataclasses import dataclass, field
from pathlib import PurePosixPath

from . import lzstring

PLUGIN_VERSION = "2.25.3"
PLUGIN_HEADER = "\n".join([
    "---", "", "excalidraw-plugin: parsed", "tags: [excalidraw]", "", "---",
    "==⚠  Switch to EXCALIDRAW VIEW in the MORE OPTIONS menu of this document. ⚠== You can decompress Drawing data with the "
    "command palette: 'Decompress current Excalidraw file'. For more info check in plugin settings under 'Saving'",
    "", "",
])
CHUNK = 256
DRAWING = re.compile(r"\n##? Drawing\n[^`]*```(compressed-json|json)\n")
TEXT_HEADING = "## Text Elements\n"
SECTION_STOPS = ("## Element Links\n", "## Embedded Files\n", "%%\n")
TEXT_ENTRY = re.compile(r"(?s)(.*?) \^([A-Za-z0-9_-]+)\n\n")
EMBEDDED = re.compile(r"(?m)^([A-Za-z0-9_-]+): \[\[(.+?)\]\]\s*$")
LOSSY = "Este arquivo tem texto que não é UTF-8 válido; o Wisp abre só para leitura para não alterá-lo."


class DrawingError(ValueError):
    pass


def kind_of(path: str) -> str | None:
    lowered = path.lower()
    if lowered.endswith((".excalidraw.md", ".excalidraw")):
        return "excalidraw"
    return "canvas" if lowered.endswith(".canvas") else None


def _chunked(base64_text: str) -> str:
    return "\n\n".join(base64_text[i : i + CHUNK] for i in range(0, len(base64_text), CHUNK))


def _indent(scene_text: str) -> str:
    lines = scene_text.split("\n", 2)
    if len(lines) < 2:
        return "\t"
    lead = lines[1][: len(lines[1]) - len(lines[1].lstrip(" \t"))]
    return lead or "\t"


def _dump(scene: dict, indent: str) -> str:
    return json.dumps(scene, indent=indent, ensure_ascii=False)


def _scene(text: str) -> dict:
    try:
        scene = json.loads(text)
    except ValueError as error:
        raise DrawingError(f"A cena do desenho não é um JSON válido ({error}).") from error
    if not isinstance(scene, dict):
        raise DrawingError("A cena do desenho não é um JSON válido (a raiz não é um objeto).")
    return scene


@dataclass
class ExcalidrawFile:
    container: str
    encoding: str
    scene: dict
    prefix: str = ""
    trailer: str = ""
    indent: str = "\t"
    trailing_newline: bool = True
    crlf: bool = False
    read_only: str | None = None
    raw_texts: dict[str, str] = field(default_factory=dict)
    loaded_texts: dict[str, str] = field(default_factory=dict)

    def set_scene(self, scene: dict) -> None:
        self.scene = scene

    def _text_elements(self) -> list[dict]:
        return [e for e in self.scene.get("elements", []) if isinstance(e, dict) and e.get("type") == "text" and not e.get("isDeleted")]

    def _text_section(self) -> str:
        blocks = []
        for element in self._text_elements():
            ident = str(element.get("id", ""))
            shown = str(element.get("text", ""))
            raw = self.raw_texts.get(ident) if self.loaded_texts.get(ident) == shown else None
            blocks.append(f"{raw if raw is not None else element.get('originalText', shown)} ^{ident}\n\n")
        return TEXT_HEADING + "".join(blocks)

    def _prefix_with_texts(self) -> str:
        start = self.prefix.find(TEXT_HEADING)
        if start < 0:
            return self.prefix
        body = start + len(TEXT_HEADING)
        stops = [i for i in (self.prefix.find(s, body) for s in SECTION_STOPS) if i >= 0]
        stop = min(stops) if stops else len(self.prefix)
        return self.prefix[:start] + self._text_section() + self.prefix[stop:]

    def serialized(self) -> str:
        text = self._serialized_lf()
        return text.replace("\n", "\r\n") if self.crlf else text

    def _serialized_lf(self) -> str:
        if self.container == "plain":
            return _dump(self.scene, self.indent) + ("\n" if self.trailing_newline else "")
        scene_text = _dump(self.scene, self.indent)
        if self.encoding == "compressed":
            body = f"```compressed-json\n{_chunked(lzstring.compress_to_base64(scene_text))}\n```\n%%"
        else:
            body = f"```json\n{scene_text}\n```\n%%"
        return self._prefix_with_texts() + "## Drawing\n" + body + self.trailer

    def embedded_files(self) -> dict[str, str]:
        return {m.group(1): m.group(2) for m in EMBEDDED.finditer(self.prefix[self.prefix.find("## Embedded Files") :])} \
            if "## Embedded Files" in self.prefix else {}


def parse_excalidraw(text: str, name: str, lossy: bool = False) -> ExcalidrawFile:
    crlf = "\r\n" in text
    file = _parse_lf(text.replace("\r\n", "\n") if crlf else text, name, lossy)
    file.crlf = crlf
    return file


def _parse_lf(text: str, name: str, lossy: bool) -> ExcalidrawFile:
    if name.lower().endswith(".excalidraw") and not name.lower().endswith(".md"):
        file = ExcalidrawFile("plain", "json", _scene(text), indent=_indent(text), trailing_newline=text.endswith("\n"))
        file.read_only = LOSSY if lossy else None
        return file
    match = DRAWING.search(text)
    if not match:
        raise DrawingError('O arquivo não tem a seção "## Drawing" do Excalidraw.')
    compressed = match.group(1) == "compressed-json"
    body_start = match.end()
    fence = text.find("```\n", body_start)
    if fence < 0:
        fence = text.rfind("```")
        if fence < body_start or text[fence:].strip("`\n") != "":
            raise DrawingError('O arquivo não tem a seção "## Drawing" do Excalidraw.')
    body = text[body_start:fence]
    rest = text[fence + 4 :] if text.startswith("```\n", fence) else ""
    if rest.startswith("%%"):
        rest = rest[2:]
    if compressed:
        try:
            scene_text = lzstring.decompress_from_base64(re.sub(r"[\r\n]", "", body))
        except lzstring.TooLarge as error:
            raise DrawingError("Os dados comprimidos do desenho expandem além do limite seguro (50 MB).") from error
        if scene_text is None or not scene_text:
            raise DrawingError("Os dados comprimidos do desenho estão corrompidos.")
    else:
        scene_text = body
    scene = _scene(scene_text)
    prefix = text[: match.start() + 1]
    file = ExcalidrawFile("markdown", "compressed" if compressed else "json", scene, prefix=prefix, trailer=rest, indent=_indent(scene_text))
    file.read_only = LOSSY if lossy else None
    start = prefix.find(TEXT_HEADING)
    if start >= 0:
        region = prefix[start + len(TEXT_HEADING) :]
        stops = [i for i in (region.find(s) for s in SECTION_STOPS) if i >= 0]
        region = region[: min(stops)] if stops else region
        for entry in TEXT_ENTRY.finditer(region):
            file.raw_texts[entry.group(2)] = entry.group(1)
    for element in file._text_elements():
        file.loaded_texts[str(element.get("id", ""))] = str(element.get("text", ""))
    return file


def blank_scene() -> dict:
    return {
        "type": "excalidraw", "version": 2,
        "source": f"https://github.com/zsviczian/obsidian-excalidraw-plugin/releases/tag/{PLUGIN_VERSION}",
        "elements": [], "appState": {"gridSize": None, "viewBackgroundColor": "#ffffff"}, "files": {},
    }


def blank_excalidraw() -> str:
    file = ExcalidrawFile("markdown", "compressed", blank_scene(), prefix=f"{PLUGIN_HEADER}# Excalidraw Data\n\n{TEXT_HEADING}%%\n")
    return file.serialized()


def blank_canvas() -> str:
    return json.dumps({"nodes": [], "edges": []}, indent="\t") + "\n"


def parse_canvas(text: str) -> dict:
    try:
        data = json.loads(text)
    except ValueError as error:
        raise DrawingError(f"O canvas não é um JSON válido ({error}).") from error
    if not isinstance(data, dict):
        raise DrawingError("O canvas não é um JSON válido (a raiz não é um objeto).")
    for key in ("nodes", "edges"):
        if key in data and not isinstance(data[key], list):
            raise DrawingError(f"O canvas tem \"{key}\" que não é uma lista.")
    data.setdefault("nodes", [])
    data.setdefault("edges", [])
    return data


MAX_EMBED_BYTES = 25 * 1024 * 1024


def data_url(name: str, data: bytes) -> str | None:
    mime = mimetypes.guess_type(name)[0]
    if not mime or not mime.startswith("image/") or len(data) > MAX_EMBED_BYTES:
        return None
    return f"data:{mime};base64,{base64.b64encode(data).decode('ascii')}"


def files_payload(file: ExcalidrawFile, read_attachment) -> dict:
    files = dict(file.scene.get("files") or {})
    for ident, target in file.embedded_files().items():
        if ident in files:
            continue
        name = PurePosixPath(target.split("|")[0].split("#")[0]).name
        data = read_attachment(target.split("|")[0].split("#")[0])
        url = data_url(name, data) if data is not None else None
        if url:
            files[ident] = {"id": ident, "mimeType": url[5 : url.index(";")], "dataURL": url, "created": 0}
    return files
