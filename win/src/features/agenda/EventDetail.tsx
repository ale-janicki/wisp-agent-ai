import { useState } from "react";
import { useOpenExternal } from "../home/external";
import { useRichApi } from "../home/richApi";
import { whenLabel, type CalEvent } from "./calendar";
import type { Choice } from "./types";
import styles from "./AgendaTab.module.css";

const CHOICES: { choice: Choice; label: string }[] = [
  { choice: "accepted", label: "Sim" },
  { choice: "tentative", label: "Talvez" },
  { choice: "declined", label: "Não" },
];
const STATUS_LABEL: Record<string, string> = { accepted: "aceitou", declined: "recusou", tentative: "talvez", needsAction: "sem resposta" };

export function EventDetail({ event, onClose, onChanged }: { event: CalEvent; onClose: () => void; onChanged: () => void }) {
  const api = useRichApi("agenda");
  const openExternal = useOpenExternal();
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [asking, setAsking] = useState(false);

  const guests = event.attendees.filter((a) => !a.me).length;
  const respond = async (choice: Choice) => {
    setBusy(true);
    setProblem(null);
    try {
      await api.post(`/events/${encodeURIComponent(event.id)}/rsvp`, { choice });
      onChanged();
    } catch (error) {
      setProblem(error instanceof Error ? error.message : "Não consegui responder ao convite.");
    } finally {
      setBusy(false);
    }
  };
  const remove = async () => {
    setAsking(false);
    try {
      await api.delete(`/events/${encodeURIComponent(event.id)}`);
      onClose();
      onChanged();
    } catch (error) {
      setProblem(error instanceof Error ? error.message : "Não consegui apagar o evento.");
    }
  };
  const current = CHOICES.find((c) => c.choice === event.my_status)?.choice ?? null;
  const name = event.title || "Sem título";

  return (
    <aside className={styles.detail} aria-label="Evento">
      <header className={styles.detailHead}>
        <span className={styles.caption}>Evento</span>
        <button type="button" className={styles.icon} onClick={onClose} title="Fechar" aria-label="Fechar">
          ✕
        </button>
      </header>
      <h3 className={styles.detailTitle}>{name}</h3>
      <div>{whenLabel(event)}</div>
      {event.location && <div className={styles.secondary}>{event.location}</div>}
      {event.meeting && (
        <button type="button" className={`${styles.pill} ${styles.accent}`} onClick={() => openExternal(event.meeting!.url)} title={event.meeting.provider}>
          Entrar
        </button>
      )}
      {event.can_respond && (
        <div className={styles.rsvp}>
          <span className={styles.rsvpLabel}>Vai?</span>
          <div role="radiogroup" aria-label="Vai?" className={styles.segmented}>
            {CHOICES.map(({ choice, label }) => (
              <button key={choice} type="button" role="radio" aria-checked={current === choice} disabled={busy} className={current === choice ? styles.segOn : ""} onClick={() => void respond(choice)}>
                {label}
              </button>
            ))}
          </div>
        </div>
      )}
      {problem && (
        <div className={styles.error} role="alert">
          {problem}
        </div>
      )}
      {event.attendees.length > 0 && (
        <section>
          <div className={styles.caption}>Convidados</div>
          <ul className={styles.guests}>
            {event.attendees.map((a) => (
              <li key={a.email ?? a.name}>
                <span>{a.name}</span>
                <span className={styles.caption}>{STATUS_LABEL[a.status] ?? a.status}</span>
              </li>
            ))}
          </ul>
        </section>
      )}
      {event.notes && (
        <section>
          <div className={styles.caption}>Notas</div>
          <p className={styles.notes}>{event.notes}</p>
        </section>
      )}
      <footer className={styles.detailFoot}>
        <button type="button" className={`${styles.pill} ${styles.danger}`} onClick={() => setAsking(true)}>
          Apagar
        </button>
      </footer>
      {asking && (
        <div className={styles.overlay}>
          <div role="dialog" aria-label="Apagar evento" className={styles.sheet}>
            <h4 className={styles.sheetTitle}>{`Apagar "${name}"?`}</h4>
            <p className={guests > 0 ? styles.error : styles.secondary}>
              {guests > 0 ? `${guests} ${guests === 1 ? "convidado receberá" : "convidados receberão"} um cancelamento. Isso não pode ser desfeito.` : "Isso não pode ser desfeito."}
            </p>
            <button type="button" className={`${styles.pill} ${styles.danger}`} onClick={() => void remove()}>
              Apagar
            </button>
            <button type="button" className={styles.pill} onClick={() => setAsking(false)}>
              Cancelar
            </button>
          </div>
        </div>
      )}
    </aside>
  );
}
