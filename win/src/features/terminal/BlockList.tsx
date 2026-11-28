import { useCallback, useLayoutEffect, useMemo, useRef } from "react";
import { BlockRow, blockText, type BlockActions } from "./BlockRow";
import type { CopyKind } from "./blocks";
import type { TerminalSession } from "./session";
import { useSession } from "./hooks";
import styles from "./Pane.module.css";

type Props = { session: TerminalSession; onNotice: (text: string) => void; findQuery: string; findIndex: number };

export function BlockList({ session, onNotice, findQuery, findIndex }: Props) {
  const version = useSession(session);
  const scroller = useRef<HTMLDivElement>(null);
  const follows = useRef(true);

  const actions = useMemo<BlockActions>(
    () => ({
      copy: (id: number, kind: CopyKind) => {
        const block = session.blocks.block(id);
        if (!block) return;
        void navigator.clipboard.writeText(blockText(block, kind));
      },
      rerun: (id: number) => {
        const decision = session.rerun(id);
        if (!decision.ok) onNotice(decision.refusal);
      },
      scrollTo: (id: number, where: "top" | "end") => {
        const node = scroller.current?.querySelector<HTMLElement>(`[data-block="${id}"]`);
        if (!node || !scroller.current) return;
        follows.current = false;
        scroller.current.scrollTop = where === "top" ? node.offsetTop : node.offsetTop + node.offsetHeight - scroller.current.clientHeight;
      },
      select: (id: number) => session.selectBlock(id),
    }),
    [session, onNotice],
  );

  useLayoutEffect(() => {
    const node = scroller.current;
    if (node && follows.current) node.scrollTop = node.scrollHeight;
  }, [version]);

  const onScroll = useCallback(() => {
    const node = scroller.current;
    if (node) follows.current = node.scrollHeight - node.scrollTop - node.clientHeight < 24;
  }, []);

  const matches = useMemo(() => {
    const query = findQuery.trim().toLowerCase();
    if (!query) return [] as number[];
    return session.blocks.blocks
      .filter((b) => b.command.toLowerCase().includes(query) || blockText(b, "output").toLowerCase().includes(query))
      .map((b) => b.id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [findQuery, version, session]);

  useLayoutEffect(() => {
    const id = matches[findIndex];
    if (id === undefined) return;
    const node = scroller.current?.querySelector<HTMLElement>(`[data-block="${id}"]`);
    if (node && scroller.current) {
      follows.current = false;
      scroller.current.scrollTop = node.offsetTop;
    }
  }, [matches, findIndex]);

  const { blocks, live } = session;
  return (
    <div className={styles.blocks} ref={scroller} onScroll={onScroll} data-testid="blocks">
      {blocks.blocks.map((block) => (
        <BlockRow
          key={block.id}
          block={block}
          rev={block.rev}
          selected={session.selectedBlockId === block.id}
          live={live && live.id === block.id ? live : null}
          actions={actions}
        />
      ))}
    </div>
  );
}

export const countMatches = (session: TerminalSession, query: string): number => {
  const q = query.trim().toLowerCase();
  if (!q) return 0;
  return session.blocks.blocks.filter((b) => b.command.toLowerCase().includes(q) || blockText(b, "output").toLowerCase().includes(q)).length;
};
