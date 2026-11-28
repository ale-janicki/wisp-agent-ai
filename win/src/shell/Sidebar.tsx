import type { Feature } from "../features/types";
import { WindowIcon } from "./icons";
import styles from "./Sidebar.module.css";

type Props = {
  features: readonly Feature[];
  selected: string;
  onSelect: (id: string) => void;
  compact: boolean;
  windowed: boolean;
  onToggleWindow: () => void;
  status: { label: string; tone: "ok" | "busy" | "error" };
};

export function Sidebar({ features, selected, onSelect, compact, windowed, onToggleWindow, status }: Props) {
  const row = (f: Feature) => {
    const on = f.id === selected;
    return (
      <button
        key={f.id}
        type="button"
        className={`${styles.row} ${on ? styles.on : ""}`}
        aria-current={on ? "page" : undefined}
        aria-label={f.label}
        title={compact ? f.label : undefined}
        onClick={() => onSelect(f.id)}
      >
        <span className={styles.icon}>
          <f.icon size={16} />
        </span>
        {!compact && <span className={styles.label}>{f.label}</span>}
      </button>
    );
  };

  return (
    <nav className={styles.sidebar} aria-label="Abas" data-compact={compact}>
      <div className={styles.header}>
        <span className={styles.avatar} aria-hidden />
        {!compact && (
          <div className={styles.who}>
            <span className={styles.name}>Wisp</span>
            <span className={styles.status}>
              <span className={`${styles.dot} ${styles[status.tone]}`} aria-hidden />
              {status.label}
            </span>
          </div>
        )}
        {!compact && (
          <button
            type="button"
            className={styles.window}
            onClick={onToggleWindow}
            title={windowed ? "Voltar ao painel" : "Abrir em janela"}
            aria-label={windowed ? "Voltar ao painel" : "Abrir em janela"}
            aria-pressed={windowed}
          >
            <WindowIcon size={14} />
          </button>
        )}
      </div>
      <div className={styles.list}>{features.filter((f) => f.placement !== "bottom").map(row)}</div>
      <div className={styles.bottom}>{features.filter((f) => f.placement === "bottom").map(row)}</div>
    </nav>
  );
}
