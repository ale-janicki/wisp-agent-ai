import { useEffect, useRef, useState } from "react";
import { useRichApi } from "../home/richApi";
import type { Quick } from "./types";
import styles from "./AgendaTab.module.css";

const DEBOUNCE = 250;
const PLACEHOLDER = "almoço amanhã 13h por 1h · reunião sexta 10-11 no calendário Trabalho";
const dayFmt = new Intl.DateTimeFormat("pt-BR", { weekday: "short", day: "numeric", month: "short" });
const clockFmt = new Intl.DateTimeFormat("pt-BR", { hour: "2-digit", minute: "2-digit", hour12: false });

const asDate = (value: string) => (value.length === 10 ? new Date(Number(value.slice(0, 4)), Number(value.slice(5, 7)) - 1, Number(value.slice(8, 10))) : new Date(value));

export function summary(q: Quick): string {
  const start = asDate(q.start);
  const when = q.all_day ? `${dayFmt.format(start)} · dia todo` : `${dayFmt.format(start)} · ${clockFmt.format(start)}–${clockFmt.format(asDate(q.end))}`;
  return [q.title || "Sem título", when, q.calendar_name, q.location].filter(Boolean).join(" · ");
}

export function QuickBar({ now, onCreated }: { now: () => Date; onCreated: () => void }) {
  const api = useRichApi("agenda");
  const [text, setText] = useState("");
  const [preview, setPreview] = useState<Quick | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const ticket = useRef(0);

  useEffect(() => {
    const mine = ++ticket.current;
    if (!text.trim()) return void setPreview(null);
    const timer = setTimeout(() => {
      api
        .post<{ event: Quick | null }>("/parse", { text, now: now().toISOString() })
        .then((r) => mine === ticket.current && setPreview(r.event))
        .catch(() => mine === ticket.current && setPreview(null));
    }, DEBOUNCE);
    return () => clearTimeout(timer);
  }, [api, text, now]);

  const commit = async () => {
    if (!text.trim()) return;
    setProblem(null);
    try {
      const parsed = (await api.post<{ event: Quick | null }>("/parse", { text, now: now().toISOString() })).event;
      if (!parsed) return;
      const body: Record<string, unknown> = { title: parsed.title || "Sem título", start: parsed.start, end: parsed.end, all_day: parsed.all_day };
      if (parsed.location) body.location = parsed.location;
      await api.post("/events", body);
      ticket.current += 1;
      setText("");
      setPreview(null);
      onCreated();
    } catch (error) {
      setProblem(error instanceof Error ? error.message : "Não consegui criar o evento.");
    }
  };

  return (
    <div className={styles.quick}>
      <div className={styles.quickField}>
        <span className={styles.spark} aria-hidden>
          ✦
        </span>
        <input
          className={styles.quickInput}
          placeholder={PLACEHOLDER}
          aria-label="Novo evento"
          value={text}
          autoFocus
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.nativeEvent.isComposing) void commit();
          }}
        />
        <button type="button" className={`${styles.pill} ${styles.accent}`} disabled={!text.trim()} onClick={() => void commit()}>
          Criar
        </button>
      </div>
      {preview && <div className={styles.quickPreview}>{summary(preview)}</div>}
      {problem && (
        <div className={styles.error} role="alert">
          {problem}
        </div>
      )}
    </div>
  );
}
