import { useCallback, useEffect, useMemo, useState } from "react";
import { useFeatureEvents } from "../../shell/context";
import { useRichApi } from "../home/richApi";
import { parseEvent, rangeFor, startOfDay, step, titleFor, weekStart, type CalEvent } from "./calendar";
import { ConnectGoogle } from "./ConnectGoogle";
import { EventDetail } from "./EventDetail";
import { MonthView } from "./MonthView";
import { QuickBar } from "./QuickBar";
import { SidePanel } from "./SidePanel";
import { TimeGrid, weekDays } from "./TimeGrid";
import type { ApiEvent, Status, ViewMode } from "./types";
import styles from "./AgendaTab.module.css";

const MODE_KEY = "wisp.agenda.mode";
const MODES: { mode: ViewMode; label: string }[] = [
  { mode: "day", label: "Dia" },
  { mode: "week", label: "Semana" },
  { mode: "month", label: "Mês" },
];

function savedMode(): ViewMode {
  try {
    const value = localStorage.getItem(MODE_KEY);
    return value === "day" || value === "week" || value === "month" ? value : "week";
  } catch {
    return "week";
  }
}

export function AgendaTab({ now = () => new Date() }: { now?: () => Date } = {}) {
  const api = useRichApi("agenda");
  const [status, setStatus] = useState<Status | null>(null);
  const [mode, setModeState] = useState<ViewMode>(savedMode);
  const [anchor, setAnchor] = useState(() => startOfDay(now()));
  const [events, setEvents] = useState<CalEvent[]>([]);
  const [problem, setProblem] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [quickOpen, setQuickOpen] = useState(false);
  const [sideOpen, setSideOpen] = useState(false);
  const [tick, setTick] = useState(0);

  const loadStatus = useCallback(() => api.get<Status>("/status").then(setStatus).catch(() => {}), [api]);
  useEffect(() => void loadStatus(), [loadStatus]);
  useFeatureEvents("agenda", (event) => {
    if (event.type === "auth") void loadStatus();
  });

  const connected = status?.connected === true;
  const range = useMemo(() => rangeFor(mode, anchor), [mode, anchor]);
  useEffect(() => {
    if (!connected) return;
    let alive = true;
    api
      .get<{ items: ApiEvent[] }>("/events", { start: range.start.toISOString(), end: range.end.toISOString() })
      .then((r) => {
        if (!alive) return;
        setEvents(r.items.map(parseEvent));
        setProblem(null);
      })
      .catch((error) => alive && setProblem(error instanceof Error ? error.message : "Não consegui ler a agenda."));
    return () => {
      alive = false;
    };
  }, [api, connected, range, tick]);

  const setMode = (next: ViewMode) => {
    setModeState(next);
    try {
      localStorage.setItem(MODE_KEY, next);
    } catch {
      return;
    }
  };
  const reload = () => setTick((n) => n + 1);
  const openDay = (day: Date) => {
    setAnchor(startOfDay(day));
    setMode("day");
  };
  const selected = events.find((e) => e.id === selectedId) ?? null;
  const current = now();

  if (status === null) return <div className={styles.tab} aria-busy />;
  if (!connected) {
    return (
      <div className={styles.tab}>
        <ConnectGoogle status={status} reload={loadStatus} />
      </div>
    );
  }

  const days = mode === "day" ? [anchor] : weekDays(weekStart(anchor));
  return (
    <div className={styles.tab}>
      <div className={styles.toolbar}>
        <button type="button" className={`${styles.icon} ${sideOpen ? styles.on : ""}`} onClick={() => setSideOpen((o) => !o)} aria-label="Calendários, lembretes e fusos" title="Calendários, lembretes e fusos">
          ☰
        </button>
        <button type="button" className={styles.pill} onClick={() => setAnchor(startOfDay(now()))} title="Hoje (T)">
          Hoje
        </button>
        <button type="button" className={styles.icon} onClick={() => setAnchor(step(mode, anchor, -1))} aria-label="Anterior" title="Anterior (K)">
          ‹
        </button>
        <button type="button" className={styles.icon} onClick={() => setAnchor(step(mode, anchor, 1))} aria-label="Próximo" title="Próximo (J)">
          ›
        </button>
        <h2 className={styles.title}>{titleFor(mode, anchor)}</h2>
        <span className={styles.spacer} />
        <div role="tablist" aria-label="Visualização" className={styles.segmented}>
          {MODES.map((m) => (
            <button key={m.mode} type="button" role="tab" aria-selected={mode === m.mode} className={mode === m.mode ? styles.segOn : ""} onClick={() => setMode(m.mode)}>
              {m.label}
            </button>
          ))}
        </div>
        <button type="button" className={`${styles.icon} ${quickOpen ? styles.on : ""}`} onClick={() => setQuickOpen((o) => !o)} aria-label="Novo evento" title="Novo evento (N)">
          +
        </button>
      </div>
      {quickOpen && (
        <QuickBar
          now={now}
          onCreated={() => {
            reload();
          }}
        />
      )}
      {problem && (
        <div className={styles.error} role="alert">
          {problem}
        </div>
      )}
      <div className={styles.workspace}>
        {sideOpen && <SidePanel status={status} reload={loadStatus} />}
        <div className={styles.main}>
          {mode === "month" ? (
            <MonthView anchor={anchor} events={events} now={current} selectedId={selectedId} onSelect={(e) => setSelectedId(e.id)} onOpenDay={openDay} />
          ) : (
            <TimeGrid days={days} events={events} now={current} selectedId={selectedId} onSelect={(e) => setSelectedId(e.id)} onOpenDay={openDay} />
          )}
        </div>
        {selected && <EventDetail key={selected.id} event={selected} onClose={() => setSelectedId(null)} onChanged={reload} />}
      </div>
    </div>
  );
}

