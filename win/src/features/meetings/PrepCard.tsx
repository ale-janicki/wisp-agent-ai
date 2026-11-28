import { useState } from "react";
import type { CheckItem } from "./types";
import styles from "./Meetings.module.css";

type Props = { prep: CheckItem[]; onPrepare: (title: string, description: string) => Promise<void> | void };

export function PrepCard({ prep, onPrepare }: Props) {
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const ready = (title + description).trim().length > 0;
  return (
    <section className={styles.card} aria-label="Preparar a reunião">
      <h3 className={styles.cardTitle}>Preparar a próxima reunião</h3>
      <input className={styles.input} placeholder="Assunto" aria-label="Assunto" value={title} onChange={(e) => setTitle(e.target.value)} />
      <textarea
        className={styles.input}
        placeholder="Pauta, participantes, o que quer decidir"
        aria-label="Descrição"
        rows={3}
        value={description}
        onChange={(e) => setDescription(e.target.value)}
      />
      <p className={styles.hint}>O assunto e a descrição vão para o motor de IA ativo.</p>
      <button type="button" className={styles.ghost} disabled={!ready} onClick={() => void onPrepare(title, description)}>
        Preparar
      </button>
      {prep.length > 0 && (
        <ul className={styles.items} aria-label="Checklist preparado">
          {prep.map((item) => (
            <li key={item.id}>{item.text}</li>
          ))}
        </ul>
      )}
    </section>
  );
}
