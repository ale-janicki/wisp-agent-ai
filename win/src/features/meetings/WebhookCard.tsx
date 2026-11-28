import { useState } from "react";
import type { WebhookOffer } from "./types";
import styles from "./Meetings.module.css";

type Props = { offer: WebhookOffer; onAllow: () => void; onDismiss: () => void };

export function WebhookCard({ offer, onAllow, onDismiss }: Props) {
  const [raw, setRaw] = useState(false);
  const [pretty, setPretty] = useState(false);
  return (
    <section className={styles.card} aria-label="Enviar para o webhook">
      <h3 className={styles.cardTitle}>Enviar o resumo para o webhook?</h3>
      <p className={styles.mono}>{offer.masked_url}</p>
      <p className={styles.preview}>{offer.preview}</p>
      <p className={styles.hint}>
        {offer.size}
        {offer.signed ? " · assinado" : ""} · O resumo e os pontos são saída do modelo e podem citar falas. Nada sai antes do
        Permitir.
      </p>
      <button type="button" className={styles.link} onClick={() => setRaw(!raw)} aria-expanded={raw}>
        Conteúdo exato
      </button>
      {raw && (
        <>
          <pre className={styles.code}>{offer.body}</pre>
          <button type="button" className={styles.link} onClick={() => setPretty(!pretty)} aria-expanded={pretty}>
            formatado
          </button>
          {pretty && <pre className={styles.code}>{offer.formatted}</pre>}
        </>
      )}
      <div className={styles.actions}>
        <button type="button" className={styles.primary} onClick={onAllow}>
          Permitir
        </button>
        <button type="button" className={styles.ghost} onClick={onDismiss}>
          Agora não
        </button>
      </div>
    </section>
  );
}
