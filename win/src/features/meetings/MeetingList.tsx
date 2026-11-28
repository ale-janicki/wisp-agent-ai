import type { Row, Tone } from "./types";
import styles from "./Meetings.module.css";

const TONES: Record<Tone, string> = {
  recording: styles.toneRecording ?? "",
  working: styles.toneWorking ?? "",
  ready: styles.toneReady ?? "",
  failed: styles.toneFailed ?? "",
};

type Props = {
  rows: Row[] | null;
  selected: string | null;
  recordingId: string | null;
  onSelect: (id: string) => void;
  onSettings: () => void;
  settingsOpen: boolean;
};

export function MeetingList({ rows, selected, recordingId, onSelect, onSettings, settingsOpen }: Props) {
  return (
    <div className={styles.list}>
      <div className={styles.listHead}>
        <span className={styles.heading}>Reuniões</span>
        <button
          type="button"
          className={`${styles.gear} ${settingsOpen ? styles.gearOn : ""}`}
          onClick={onSettings}
          title="Ajustes das reuniões"
          aria-label="Ajustes das reuniões"
          aria-pressed={settingsOpen}
        >
          ⚙
        </button>
      </div>
      <div className={styles.rows} role="list">
        {rows === null && (
          <div aria-label="Carregando reuniões" className={styles.skeletons}>
            {[0, 1, 2].map((n) => (
              <div key={n} className={styles.skeleton} />
            ))}
          </div>
        )}
        {rows?.length === 0 && <div className={styles.empty}>Nenhuma reunião ainda.</div>}
        {rows?.map((row) => (
          <button
            type="button"
            role="listitem"
            key={row.id}
            className={`${styles.row} ${row.id === selected ? styles.current : ""}`}
            onClick={() => onSelect(row.id)}
          >
            <span className={styles.rowTitle}>{row.title}</span>
            <span className={styles.rowMeta}>
              {row.date_text} · {row.duration_text}
            </span>
            <span className={`${styles.badge} ${TONES[row.badge.tone]}`} data-live={row.id === recordingId}>
              {row.badge.label}
            </span>
          </button>
        ))}
      </div>
    </div>
  );
}
