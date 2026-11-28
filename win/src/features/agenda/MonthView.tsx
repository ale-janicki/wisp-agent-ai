import { eventsOnDay, monthWeeks, sameDay, type CalEvent } from "./calendar";
import styles from "./AgendaTab.module.css";

const SHOWN = 3;
const weekdays = Array.from({ length: 7 }, (_, i) => new Intl.DateTimeFormat("pt-BR", { weekday: "short" }).format(new Date(2026, 10, 29 + i)));

type Props = { anchor: Date; events: CalEvent[]; now: Date; selectedId: string | null; onSelect: (e: CalEvent) => void; onOpenDay: (d: Date) => void };

export function MonthView({ anchor, events, now, selectedId, onSelect, onOpenDay }: Props) {
  const weeks = monthWeeks(anchor);
  return (
    <div className={styles.month}>
      <div className={styles.monthHead}>
        {weekdays.map((w) => (
          <span key={w}>{w}</span>
        ))}
      </div>
      <div className={styles.monthBody} style={{ gridTemplateRows: `repeat(${weeks.length}, minmax(0, 1fr))` }}>
        {weeks.map((week) => (
          <div key={week[0]!.toISOString()} className={styles.monthWeek}>
            {week.map((day) => {
              const list = eventsOnDay(events, day);
              const today = sameDay(day, now);
              return (
                <div key={day.toISOString()} className={`${styles.monthDay} ${day.getMonth() !== anchor.getMonth() ? styles.outside : ""}`}>
                  <button type="button" className={`${styles.monthNumber} ${today ? styles.today : ""}`} onClick={() => onOpenDay(day)}>
                    {day.getDate()}
                  </button>
                  {list.slice(0, SHOWN).map((e) => (
                    <button key={e.id} type="button" className={`${styles.chip} ${e.declined ? styles.declined : ""} ${e.id === selectedId ? styles.selected : ""}`} onClick={() => onSelect(e)} title={e.title}>
                      {e.title || "Sem título"}
                    </button>
                  ))}
                  {list.length > SHOWN && (
                    <button type="button" className={styles.more} onClick={() => onOpenDay(day)}>{`+${list.length - SHOWN} mais`}</button>
                  )}
                </div>
              );
            })}
          </div>
        ))}
      </div>
    </div>
  );
}
