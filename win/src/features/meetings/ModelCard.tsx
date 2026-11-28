import type { ModelItem } from "./types";
import { sizeText } from "./view";
import styles from "./Meetings.module.css";

type Props = {
  models: ModelItem[];
  attribution: string;
  onDownload: (id: string) => void;
  onCancel: (id: string) => void;
  onlyMissing?: boolean;
};

export function ModelCard({ models, attribution, onDownload, onCancel, onlyMissing = true }: Props) {
  const shown = models.filter((m) => (onlyMissing ? m.wanted && !m.installed : true));
  if (shown.length === 0) return null;
  return (
    <section className={styles.card} aria-label="Modelos de transcrição">
      <h3 className={styles.cardTitle}>Modelos de transcrição</h3>
      <p className={styles.hint}>
        Baixados uma vez para a pasta do Wisp, nunca embutidos. O modelo pequeno transcreve durante a chamada; o grande
        revisa o texto depois.
      </p>
      {shown.map((m) => (
        <div key={m.id} className={styles.modelRow}>
          <div className={styles.modelInfo}>
            <span>{m.label}</span>
            <span className={styles.rowMeta}>
              {m.role === "live" ? "ao vivo" : "revisão"} · {sizeText(m.size_bytes)} · {m.license}
            </span>
            {m.error && (
              <span className={styles.errorText} role="alert">
                {m.error}
              </span>
            )}
          </div>
          {m.installed ? (
            <span className={styles.rowMeta}>instalado</span>
          ) : m.downloading ? (
            <>
              <progress className={styles.progress} value={m.progress ?? 0} max={1} aria-label={`Baixando ${m.label}`} />
              <button type="button" className={styles.ghost} onClick={() => onCancel(m.id)}>
                Cancelar
              </button>
            </>
          ) : (
            <button type="button" className={styles.primary} onClick={() => onDownload(m.id)}>
              Baixar
            </button>
          )}
        </div>
      ))}
      {attribution && <p className={styles.hint}>{attribution}</p>}
    </section>
  );
}
