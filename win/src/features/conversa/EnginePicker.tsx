import type { EngineId, EngineOverview } from "../../api/types";
import styles from "./EnginePicker.module.css";

type Props = { overview: EngineOverview | null; onChoose: (engine: EngineId) => void };

export function EnginePicker({ overview, onChoose }: Props) {
  if (!overview) return null;
  const active = overview.engines.find((e) => e.id === overview.active);
  return (
    <select
      className={styles.picker}
      aria-label="Motor"
      value={overview.active}
      title={active?.note ?? active?.name}
      onChange={(e) => onChoose(e.target.value as EngineId)}
    >
      {overview.engines.map((e) => (
        <option key={e.id} value={e.id} title={e.note ?? undefined}>
          {e.ready ? e.name : `${e.name} (indisponível)`}
        </option>
      ))}
    </select>
  );
}
