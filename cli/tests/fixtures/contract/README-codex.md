The `codex-*-from-docs.jsonl` files are NOT captured from a real Codex run (Codex was not installed on the machine that wrote them).
They are built from the event schema in openai/codex `codex-rs/exec/src/exec_events.rs` and the sample stream in
https://developers.openai.com/codex/noninteractive. Replace them with real captures when Codex is available.
`codex-agents-block.md` and `codex-config-block.toml` are Wisp's own rendering output (`wisp.setup.codex`), pinned here.
