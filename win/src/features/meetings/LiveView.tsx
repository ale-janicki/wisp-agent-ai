import { useEffect, useRef, useState } from "react";
import type { Line, MeetingsState } from "./types";
import { CopilotPanel } from "./CopilotPanel";
import { shouldFollow } from "./view";
import styles from "./Meetings.module.css";

type Props = {
  state: MeetingsState;
  lines: Line[];
  brainSearch: boolean;
  onBookmark: () => void;
  onToggle: (changes: Record<string, boolean>) => void;
  onDismissNudge: () => void;
  onCheck: (id: string, done: boolean) => void;
};

export function LiveView({ state, lines, brainSearch, onBookmark, onToggle, onDismissNudge, onCheck }: Props) {
  const scroller = useRef<HTMLDivElement>(null);
  const [following, setFollowing] = useState(true);

  useEffect(() => {
    const el = scroller.current;
    if (el && following) el.scrollTop = el.scrollHeight;
  }, [lines, following]);

  const onScroll = () => {
    const el = scroller.current;
    if (el) setFollowing(shouldFollow(el.scrollHeight - el.scrollTop - el.clientHeight));
  };

  const jump = () => {
    const el = scroller.current;
    if (el) el.scrollTop = el.scrollHeight;
    setFollowing(true);
  };

  return (
    <div className={styles.live}>
      <div className={styles.liveMain}>
        <header className={styles.liveHead}>
          <span className={styles.detailTitle}>{state.paused ? "Pausada" : "Gravando"}</span>
          <button
            type="button"
            className={styles.ghost}
            onClick={onBookmark}
            disabled={state.phase !== "recording"}
            title="Marcar este momento"
          >
            Marcar momento
          </button>
        </header>
        {state.warnings.map((w) => (
          <div key={w} className={styles.hintBox} role="status">
            {w}
          </div>
        ))}
        {state.lag && <div className={styles.hintBox}>Transcrição atrasada</div>}
        <div className={styles.lines} ref={scroller} onScroll={onScroll} role="log" aria-label="Transcrição ao vivo">
          {lines.length === 0 && <div className={styles.empty}>Nada transcrito ainda.</div>}
          {lines.map((line) => (
            <LineRow key={line.id} line={line} />
          ))}
        </div>
        {!following && (
          <button type="button" className={styles.jump} onClick={jump}>
            Ir para o fim
          </button>
        )}
      </div>
      <CopilotPanel
        copilot={state.copilot}
        brainSearch={brainSearch}
        onToggle={onToggle}
        onDismissNudge={onDismissNudge}
        onCheck={onCheck}
      />
    </div>
  );
}

export function LineRow({ line }: { line: Line }) {
  const tone = line.is_bookmark || line.is_pause ? styles.marker : line.is_mine ? styles.mine : styles.theirs;
  return (
    <div className={`${styles.line} ${tone} ${line.is_partial ? styles.partial : ""}`}>
      <span className={styles.lineTime}>{line.time}</span>
      <span className={styles.speaker}>{line.speaker}</span>
      <span className={styles.lineText}>{line.text}</span>
    </div>
  );
}
