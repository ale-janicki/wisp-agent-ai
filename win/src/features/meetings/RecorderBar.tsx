import type { MeetingsState, Sources } from "./types";
import { clock, meterFraction, recordButton } from "./view";
import styles from "./Meetings.module.css";

type Props = {
  state: MeetingsState;
  onStart: () => void;
  onStop: () => void;
  onPause: () => void;
  onResume: () => void;
  onSources: (sources: Sources) => void;
};

export function RecorderBar({ state, onStart, onStop, onPause, onResume, onSources }: Props) {
  const button = recordButton(state.phase, state.saving);
  const recording = state.phase === "recording";
  return (
    <div className={styles.recorder}>
      <button
        type="button"
        className={`${styles.record} ${recording ? styles.recording : ""}`}
        disabled={!button.enabled}
        onClick={recording ? onStop : onStart}
      >
        <span className={styles.recordDot} aria-hidden />
        {button.title}
      </button>
      {state.phase === "idle" && (
        <select
          className={styles.select}
          aria-label="Fonte do áudio"
          value={state.sources}
          onChange={(e) => onSources(e.target.value as Sources)}
        >
          {(Object.keys(state.source_labels) as Sources[]).map((key) => (
            <option key={key} value={key}>
              {state.source_labels[key]}
            </option>
          ))}
        </select>
      )}
      {recording && (
        <>
          <button type="button" className={styles.ghost} onClick={state.paused ? onResume : onPause}>
            {state.paused ? "Retomar" : "Pausar"}
          </button>
          <span className={styles.timer} aria-label="Tempo de gravação">
            {clock(state.elapsed)}
          </span>
          <span className={styles.meter} role="meter" aria-label="Nível do áudio" aria-valuemin={0} aria-valuemax={1} aria-valuenow={meterFraction(state.levels)}>
            <span style={{ width: `${Math.round(meterFraction(state.levels) * 100)}%` }} />
          </span>
        </>
      )}
    </div>
  );
}
