import { memo, useEffect, useRef, useState } from "react";
import { blockDuration, copyText, type CopyKind, type TerminalBlock } from "./blocks";
import { plainText } from "./capture";
import type { StyledLine } from "./styled";
import { StyledLines } from "./StyledLines";
import styles from "./Pane.module.css";

export const MAX_RENDERED_LINES = 2000;

export type BlockActions = {
  copy: (id: number, kind: CopyKind) => void;
  rerun: (id: number) => void;
  scrollTo: (id: number, where: "top" | "end") => void;
  select: (id: number) => void;
};

type Props = {
  block: TerminalBlock;
  rev: number;
  selected: boolean;
  live: { lines: StyledLine[]; hidden: number } | null;
  actions: BlockActions;
};

function glyph(block: TerminalBlock): { text: string; label: string; className: string } {
  switch (block.status.kind) {
    case "running": return { text: "◐", label: "Em execução", className: styles.running! };
    case "finished": return block.status.code === 0 ? { text: "✓", label: "Terminou", className: styles.ok! } : { text: "✕", label: `Falhou (código ${block.status.code})`, className: styles.fail! };
    case "lost": return { text: "?", label: "Sem código de saída", className: styles.lost! };
  }
}

function caption(block: TerminalBlock): string | null {
  if (block.status.kind === "running") return block.interrupted ? "interrompendo…" : null;
  const seconds = block.finishedAt === null ? null : blockDuration((block.finishedAt - block.startedAt) / 1000);
  return block.interrupted ? [seconds, "interrompido"].filter(Boolean).join(" · ") : seconds;
}

export const BlockRow = memo(function BlockRow({ block, selected, live, actions }: Props) {
  const [menu, setMenu] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!menu) return;
    const close = (event: MouseEvent) => {
      if (!menuRef.current?.contains(event.target as Node)) setMenu(false);
    };
    window.addEventListener("mousedown", close);
    return () => window.removeEventListener("mousedown", close);
  }, [menu]);

  const g = glyph(block);
  const lines = block.status.kind === "running" ? (live?.lines ?? []) : (block.output ?? []);
  const hidden = block.status.kind === "running" ? (live?.hidden ?? 0) : Math.max(0, lines.length - MAX_RENDERED_LINES);
  const shown = block.status.kind === "running" ? lines : lines.length > MAX_RENDERED_LINES ? lines.slice(lines.length - MAX_RENDERED_LINES) : lines;
  const cap = caption(block);
  const command = block.command.replace(/\n+$/, "");
  const act = (run: () => void) => () => {
    setMenu(false);
    run();
  };

  return (
    <article className={styles.block} data-selected={selected} data-status={block.status.kind} data-block={block.id} onMouseDown={() => actions.select(block.id)}>
      <header className={styles.blockHead}>
        <span className={`${styles.glyph} ${g.className}`} title={g.label} aria-label={g.label}>
          {g.text}
        </span>
        <code className={styles.command}>{command || "(sem comando)"}</code>
        {cap && <span className={styles.caption}>{cap}</span>}
        <button type="button" className={styles.menuButton} aria-label="Ações do bloco" aria-expanded={menu} onClick={() => setMenu((v) => !v)}>
          ⋯
        </button>
        {menu && (
          <div className={styles.menu} role="menu" ref={menuRef}>
            <button type="button" role="menuitem" onClick={act(() => actions.copy(block.id, "command"))}>Copiar comando</button>
            <button type="button" role="menuitem" onClick={act(() => actions.copy(block.id, "output"))}>Copiar saída</button>
            <button type="button" role="menuitem" onClick={act(() => actions.copy(block.id, "commandAndOutput"))}>Copiar comando e saída</button>
            <hr />
            <button type="button" role="menuitem" onClick={act(() => actions.rerun(block.id))}>Executar de novo</button>
            <hr />
            <button type="button" role="menuitem" onClick={act(() => actions.scrollTo(block.id, "top"))}>Ir para o topo do bloco</button>
            <button type="button" role="menuitem" onClick={act(() => actions.scrollTo(block.id, "end"))}>Ir para o fim do bloco</button>
          </div>
        )}
      </header>
      {hidden > 0 && <div className={styles.hidden}>{block.status.kind === "running" ? `… ${hidden} linhas acima` : `… ${hidden} linhas anteriores (Copiar saída traz tudo)`}</div>}
      {shown.length > 0 && (
        <div className={styles.output}>
          <StyledLines lines={shown} />
        </div>
      )}
    </article>
  );
});

export const blockText = (block: TerminalBlock, kind: CopyKind): string => copyText(kind, block.command, plainText(block.output ?? []));
