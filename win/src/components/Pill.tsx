import styles from "./Pill.module.css";

export type PillTone = "idle" | "busy" | "attention" | "error";

type Props = {
  label: string;
  tone: PillTone;
  onMouseEnter: () => void;
  onMouseLeave: () => void;
  onClick: () => void;
};

export function Pill({ label, tone, onMouseEnter, onMouseLeave, onClick }: Props) {
  return (
    <button
      type="button"
      className={styles.pill}
      onMouseEnter={onMouseEnter}
      onMouseLeave={onMouseLeave}
      onClick={onClick}
    >
      <span className={`${styles.dot} ${styles[tone]}`} aria-hidden />
      <span className={styles.label}>{label}</span>
    </button>
  );
}
