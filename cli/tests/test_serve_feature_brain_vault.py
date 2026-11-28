import os
from datetime import date, datetime
import pytest

from wisp.serve.features.brain import catalog, checkbox, daily, document, links, merge, refactor, watch
from wisp.serve.features.brain.vault import Exists, InvalidName, Outside, ReadOnly, Vault, VaultError


@pytest.fixture
def root(tmp_path):
    base = tmp_path / "cofre"
    (base / "pessoas").mkdir(parents=True)
    (base / "arquivos").mkdir()
    (base / ".git").mkdir()
    (base / ".obsidian").mkdir()
    (base / "Inicio.md").write_text("# Inicio\n\nVeja [[Ana]] e [[projetos/plano#Metas|o plano]].\n\n```\n[[Ignorada]]\n```\n", encoding="utf-8")
    (base / "pessoas" / "Ana.md").write_text("---\naliases: [Aninha]\ntags: [pessoa]\n---\n# Ana\n\nVolta para [[Inicio]].\n", encoding="utf-8")
    (base / "projetos").mkdir()
    (base / "projetos" / "plano.md").write_text("# Plano\n\n## Metas\n\n- [ ] primeira\n- [x] segunda\n", encoding="utf-8")
    (base / "arquivos" / "velho.md").write_text("# Velho\n[[Ana]]\n", encoding="utf-8")
    (base / ".git" / "config").write_text("x", encoding="utf-8")
    return base


def test_vault_refuses_paths_that_leave_or_hide(root):
    vault = Vault(root)
    for bad in ["", "/etc/passwd", "../fora.md", "a/../../fora.md", ".git/config", ".obsidian/app.json", "pessoas//Ana.md", "a/.oculto.md"]:
        with pytest.raises(Outside):
            vault.path(bad)
    assert vault.path("pessoas/Ana.md") == (root / "pessoas" / "Ana.md").resolve()
    for bad in ["a:b.md", "a\\b.md"]:
        with pytest.raises(InvalidName):
            vault.validate_new(bad)


def test_vault_tree_skips_hidden_and_keeps_arquivos(root):
    paths = {e["path"] for e in Vault(root).tree()}
    assert {"Inicio.md", "pessoas", "pessoas/Ana.md", "arquivos", "arquivos/velho.md", "projetos/plano.md"} <= paths
    assert not any(p.startswith(".") or "/." in p for p in paths)
    folders = {e["path"] for e in Vault(root).tree() if e["is_folder"]}
    assert "pessoas" in folders and "Inicio.md" not in folders


def test_vault_write_is_atomic_and_keeps_crlf(root):
    vault = Vault(root)
    vault.write("Inicio.md", "a\r\nb\r\n")
    assert (root / "Inicio.md").read_bytes() == b"a\r\nb\r\n"
    assert not [p for p in root.iterdir() if p.name.startswith(".wisp-tmp")]


def test_vault_inspect_marks_binary_and_outside_symlink_read_only(root, tmp_path):
    (root / "bin.md").write_bytes(b"abc\x00def")
    text, reason = Vault(root).inspect("bin.md")
    assert reason and "UTF-8" in reason
    outside = tmp_path / "fora.md"
    outside.write_text("fora", encoding="utf-8")
    try:
        os.symlink(outside, root / "link.md")
    except (OSError, NotImplementedError):
        pytest.skip("symlinks unavailable")
    with pytest.raises(Outside):
        Vault(root).inspect("link.md")
    with pytest.raises(Outside):
        Vault(root).read_bytes("link.md")
    with pytest.raises(ReadOnly):
        Vault(root).write("link.md", "x")
    assert outside.read_text(encoding="utf-8") == "fora"


def test_vault_create_move_and_trash(root):
    trashed = []
    vault = Vault(root, trasher=lambda p: trashed.append(p.name))
    vault.create("nova.md", "# Nova\n")
    with pytest.raises(Exists):
        vault.create("nova.md", "")
    vault.move("nova.md", "pessoas/nova.md")
    assert (root / "pessoas" / "nova.md").exists()
    vault.trash("pessoas/nova.md")
    assert trashed == ["nova.md"]


def test_scan_finds_links_outside_code_and_frontmatter_links():
    text = "---\nrelacionada: \"[[Alvo]]\"\n---\nTexto [[A|alias]] e ![[img.png]] e `[[codigo]]`\n```\n[[cerca]]\n```\n[[B#Secao]] [[#aqui]]\n"
    body = [(o.name, o.heading, o.alias, o.is_embed) for o in links.scan(text)]
    assert body == [("A", "", "alias", False), ("img.png", "", None, True), ("B", "Secao", None, False), ("", "aqui", None, False)]
    assert [o.name for o in links.scan(text, include_frontmatter=True)][0] == "Alvo"
    first = links.scan("x [[Ana]] y")[0]
    assert "x [[Ana]] y"[first.name_start : first.name_end] == "Ana" and first.line == 0
    assert links.scan("[[a.png]]")[0].is_attachment


def test_catalog_resolves_like_the_python_index_and_lists_backlinks(root):
    vault = Vault(root)
    cat = catalog.Catalog.scan(vault)
    assert cat.resolve("Ana", "Inicio.md") == "pessoas/Ana.md"
    assert cat.resolve("aninha", "Inicio.md") == "pessoas/Ana.md"
    assert cat.resolve("projetos/plano", "Inicio.md") == "projetos/plano.md"
    assert cat.resolve("nao-existe", "Inicio.md") is None
    assert "arquivos/velho.md" not in cat.notes
    again = catalog.Catalog.scan(vault, previous=cat)
    assert again.reused == len(cat.notes) and again.read == 0
    found = catalog.backlinks(vault, cat, "pessoas/Ana.md")
    assert [b["path"] for b in found] == ["Inicio.md"]
    assert found[0]["contexts"][0] == {"line": 2, "text": "Veja [[Ana]] e [[projetos/plano#Metas|o plano]]."}
    out = catalog.outgoing(vault, cat, "Inicio.md")
    assert [(o["name"], o["target"]) for o in out] == [("Ana", "pessoas/Ana.md"), ("projetos/plano", "projetos/plano.md")]
    assert cat.tag_counts() == {"pessoa": 1}
    edges = cat.edges()
    assert {("Inicio.md", "pessoas/Ana.md"), ("Inicio.md", "projetos/plano.md")} <= set(edges)


def test_document_edits_one_property_and_keeps_every_other_byte():
    text = "---\ntitle: A\ntags: [a, b]\naliases:\n  - x\n  - y\nstatus: ativo\n---\nCorpo\n"
    doc = document.Document(text)
    assert doc.text == text
    props = {p["key"]: p["value"] for p in doc.properties()}
    assert props == {"title": "A", "tags": ["a", "b"], "aliases": ["x", "y"], "status": "ativo"}
    doc.set("tags", ["a", "b", "c"])
    doc.set("status", "em: curso")
    doc.set("novo", ["um", "dois"])
    doc.remove("title")
    assert doc.text == "---\ntags: [a, b, c]\naliases:\n  - x\n  - y\nstatus: \"em: curso\"\nnovo:\n  - um\n  - dois\n---\nCorpo\n"
    assert document.Document("sem frontmatter").properties() == []


def test_document_without_changes_is_byte_identical_with_crlf():
    text = "---\r\ntitle: A\r\n---\r\ncorpo\r\n"
    doc = document.Document(text)
    doc.set("title", "B")
    assert doc.text == "---\r\ntitle: B\r\n---\r\ncorpo\r\n"


def test_checkbox_toggles_only_the_box_on_the_given_line():
    text = "- [ ] a\n- [x] b\n1. [ ] c\ntexto [ ]\n"
    assert checkbox.toggle(text, 0) == "- [x] a\n- [x] b\n1. [ ] c\ntexto [ ]\n"
    assert checkbox.toggle(text, 1) == "- [ ] a\n- [ ] b\n1. [ ] c\ntexto [ ]\n"
    assert checkbox.toggle(text, 3) is None
    assert checkbox.toggle(text, 0, expected="- [ ] outra") is None
    assert checkbox.toggle(text, 0, expected="  - [ ] a") is not None


def test_merge_three_way():
    base = "a\nb\nc\n"
    assert merge.merge(base, "a\nB\nc\n", base) == ("unchanged", "")
    assert merge.merge(base, base, "a\nb\nC\n") == ("reload", "a\nb\nC\n")
    assert merge.merge(base, "A\nb\nc\n", "a\nb\nC\n") == ("merged", "A\nb\nC\n")
    kind, text = merge.merge(base, "a\nmeu\nc\n", "a\ndisco\nc\n")
    assert kind == "conflict"
    assert text == "a\n<<<<<<< minhas edições\nmeu\n=======\ndisco\n>>>>>>> no disco\nc\n"
    assert merge.has_markers(text)


def test_daily_note_config_template_and_path(root):
    (root / ".obsidian" / "daily-notes.json").write_text('{"folder": "diario", "format": "YYYY-MM-DD", "template": "modelos/daily"}', encoding="utf-8")
    (root / "modelos").mkdir()
    (root / "modelos" / "daily.md").write_text("# {{title}}\n{{date:DD/MM/YYYY}} {{time:HH:mm}} {{outra}}\n", encoding="utf-8")
    notes = ["modelos/daily.md"]
    cfg = daily.load_config(root, notes)
    assert (cfg.folder, cfg.format, cfg.template) == ("diario", "YYYY-MM-DD", "modelos/daily.md")
    day = date(2026, 3, 9)
    assert daily.path_for(cfg, day) == "diario/2026-03-09.md"
    assert daily.render("# {{title}}\n{{date:DD/MM/YYYY}} {{time:HH:mm}} {{outra}}\n", "2026-03-09", datetime(2026, 3, 9, 7, 5)) == "# 2026-03-09\n09/03/2026 07:05 {{outra}}\n"
    assert daily.moment("dddd, D [de] MMMM", day) == "Monday, 9 de March"


def test_daily_infers_folder_and_format_from_the_notes(tmp_path):
    notes = [f"dias/2026-01-0{n}.md" for n in range(1, 7)] + ["leia.md"]
    cfg = daily.load_config(tmp_path, notes)
    assert (cfg.folder, cfg.format) == ("dias", "YYYY-MM-DD")


def test_rename_rewrites_only_links_that_stop_resolving(root):
    vault = Vault(root)
    (root / "pastaX").mkdir()
    (root / "pastaX" / "Sem.md").write_text("sem titulo\n", encoding="utf-8")
    (root / "extra.md").write_text("[[Sem|rótulo]] [[Sem]] [[pastaX/Sem#Topo]] [[Aninha]] [[Inicio]] `[[Sem]]`\n", encoding="utf-8")
    cat = catalog.Catalog.scan(vault)
    plan = refactor.plan(vault, cat, "pastaX/Sem.md", "pastaY/Outro.md")
    assert [e.old_path for e in plan.edits] == ["extra.md"]
    assert plan.edits[0].new_text == "[[Outro|rótulo]] [[Outro]] [[pastaY/Outro#Topo]] [[Aninha]] [[Inicio]] `[[Sem]]`\n"
    assert plan.link_count == 3 and plan.is_complete
    refactor.apply(vault, plan)
    assert (root / "pastaY" / "Outro.md").exists() and not (root / "pastaX" / "Sem.md").exists()
    assert "[[Outro|rótulo]]" in (root / "extra.md").read_text(encoding="utf-8")


def test_rename_keeps_links_that_still_resolve_by_title_and_alias(root):
    vault = Vault(root)
    cat = catalog.Catalog.scan(vault)
    plan = refactor.plan(vault, cat, "pessoas/Ana.md", "gente/Ana Maria.md")
    assert not plan.edits
    refactor.apply(vault, plan)
    assert (root / "gente" / "Ana Maria.md").exists()
    assert catalog.Catalog.scan(vault).resolve("Ana", "Inicio.md") == "gente/Ana Maria.md"


def test_rename_follows_a_moved_folder_for_path_links(root):
    vault = Vault(root)
    (root / "extra.md").write_text("[[projetos/plano]] [[plano]]\n", encoding="utf-8")
    cat = catalog.Catalog.scan(vault)
    plan = refactor.plan(vault, cat, "projetos", "iniciativas")
    assert {e.old_path: e.new_text for e in plan.edits}["extra.md"] == "[[iniciativas/plano]] [[plano]]\n"
    assert plan.is_folder


def test_rename_refuses_existing_target_and_stale_plans(root):
    vault = Vault(root)
    cat = catalog.Catalog.scan(vault)
    with pytest.raises(Exists):
        refactor.plan(vault, cat, "Inicio.md", "projetos/plano.md")
    (root / "Sem.md").write_text("sem titulo\n", encoding="utf-8")
    (root / "extra.md").write_text("[[Sem]]\n", encoding="utf-8")
    plan = refactor.plan(vault, catalog.Catalog.scan(vault), "Sem.md", "Outro.md")
    assert plan.edits
    (root / "extra.md").write_text("mudou\n", encoding="utf-8")
    with pytest.raises(refactor.Stale):
        refactor.apply(vault, plan)
    assert (root / "Sem.md").exists() and not (root / "Outro.md").exists()


def test_watch_snapshot_reports_added_changed_removed(root):
    vault = Vault(root)
    before = watch.snapshot(vault)
    (root / "novo.md").write_text("x", encoding="utf-8")
    (root / "Inicio.md").write_text("mudou bastante\n", encoding="utf-8")
    (root / "projetos" / "plano.md").unlink()
    (root / ".git" / "config").write_text("y", encoding="utf-8")
    assert sorted(watch.diff(before, watch.snapshot(vault))) == ["Inicio.md", "novo.md", "projetos/plano.md"]
    assert watch.diff(before, before) == []


@pytest.mark.parametrize("bad", ["CON.md", "con", "a/Nul.txt", "pasta/aux.tar.gz", "COM1.md", "lpt9.md", "a/nome.", "a/nome ", "a/b.md:fluxo", "x:y/z.md"])
def test_windows_reserved_and_unsafe_names_are_refused_for_new_items_and_writes(root, bad):
    vault = Vault(root)
    with pytest.raises(InvalidName):
        vault.validate_new(bad)
    with pytest.raises(InvalidName):
        vault.write(bad, "x")
    with pytest.raises(InvalidName):
        vault.create(bad, "x")
    assert vault.validate_new("COM10.md") and vault.validate_new("console.md") and vault.validate_new("a/nul-a.md")


def test_write_retries_a_busy_target_then_reports_it_in_portuguese(root, monkeypatch):
    import wisp.serve.features.brain.vault as module

    real, calls = os.replace, []

    def flaky(src, dst):
        calls.append(1)
        if len(calls) < 3:
            raise PermissionError(13, "em uso")
        return real(src, dst)

    monkeypatch.setattr(module.os, "replace", flaky)
    monkeypatch.setattr(module.time, "sleep", lambda s: None)
    Vault(root).write("Inicio.md", "novo\n")
    assert len(calls) == 3 and (root / "Inicio.md").read_text(encoding="utf-8") == "novo\n"
    monkeypatch.setattr(module.os, "replace", lambda s, d: (_ for _ in ()).throw(PermissionError(13, "em uso")))
    with pytest.raises(VaultError, match="em uso por outro programa"):
        Vault(root).write("Inicio.md", "x")
    assert not [p for p in root.iterdir() if p.name.startswith(".wisp-tmp")]


def test_write_to_a_read_only_file_is_refused_clearly(root):
    target = root / "Inicio.md"
    target.chmod(0o444)
    try:
        with pytest.raises(ReadOnly, match="somente leitura"):
            Vault(root).write("Inicio.md", "x")
    finally:
        target.chmod(0o644)
    assert "Inicio" in target.read_text(encoding="utf-8")


def test_a_half_done_rename_apply_rolls_back_and_says_so(root, monkeypatch):
    import wisp.serve.features.brain.vault as vault_module

    module = vault_module

    vault = Vault(root)
    (root / "Sem.md").write_text("sem titulo\n", encoding="utf-8")
    (root / "r1.md").write_text("[[Sem]]\n", encoding="utf-8")
    (root / "r2.md").write_text("[[Sem]]\n", encoding="utf-8")
    plan = refactor.plan(vault, catalog.Catalog.scan(vault), "Sem.md", "Outro.md")
    assert len(plan.edits) == 2
    real = module.os.replace

    def second_fails(src, dst):
        if str(dst).endswith("r2.md"):
            raise PermissionError(13, "em uso")
        return real(src, dst)

    monkeypatch.setattr(module.os, "replace", second_fails)
    monkeypatch.setattr(module.time, "sleep", lambda s: None)
    with pytest.raises(VaultError, match="Nada foi alterado"):
        refactor.apply(vault, plan)
    assert (root / "Sem.md").exists() and not (root / "Outro.md").exists()
    assert (root / "r1.md").read_text(encoding="utf-8") == "[[Sem]]\n" and (root / "r2.md").read_text(encoding="utf-8") == "[[Sem]]\n"


def test_size_is_read_with_stat_and_the_watcher_goes_idle(root, monkeypatch):
    import asyncio

    from wisp.serve.features import brain

    assert Vault(root).size("Inicio.md") == (root / "Inicio.md").stat().st_size

    class Host:
        events = []

        def publish_feature(self, *a, **k):
            self.events.append(a)

    monkeypatch.setattr(brain, "POLL_SECONDS", 0.01)
    monkeypatch.setattr(brain, "WATCH_IDLE_SECONDS", 0.05)
    (root.parent / "cfg").mkdir(exist_ok=True)

    async def scenario():
        rt = brain.Runtime(Host())
        rt.vault = Vault(root)
        rt.touch()
        task = asyncio.get_running_loop().create_task(brain.watch_loop(rt, rt.vault))
        await asyncio.wait_for(task, 2)
        assert task.done()
        brain.ensure_watch(rt, rt.vault)
        assert rt.task is not task and not rt.task.done()
        rt.task.cancel()

    asyncio.run(scenario())
