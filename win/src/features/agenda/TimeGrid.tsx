import { useEffect, useRef } from "react";
import { addDays, clockLabel, eventsOnDay, place, sameDay, segmentOn, startOfDay, type CalEvent } from "./calendar";
import styles from "./AgendaTab.module.css";

export const HOUR_HEIGHT = 48;
const ALL_DAY_SHOWN = 2;
const HOURS = Array.from({ length: 24 }, (_, h) => h);
const longDay = new Intl.DateTimeFormat("pt-BR", { weekday: "long", day: "numeric", month: "long" });
const shortWeekday = new Intl.DateTimeFormat("pt-BR", { weekday: "short" });

type Props = {
  days: Date[];
  events: CalEvent[];
  now: Date;
  selectedId: string | null;
  onSelect: (event: CalEvent) => void;
  onOpenDay: (day: Date) => void;
};

export function TimeGrid({ days, events, now, selectedId, onSelect, onOpenDay }: Props) {
  const scroller = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = scroller.current;
    if (el) el.scrollTop = Math.max(0, (Math.min(now.getHours(), 16) - 1) * HOUR_HEIGHT);
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className={styles.grid}>
      <div className={styles.gridHead}>
        <div className={styles.gutter} />
        {days.map((day) => {
          const today = sameDay(day, now);
          const allDay = eventsOnDay(events, day).filter((e) => e.all_day);
          return (
            <div key={day.toISOString()} className={styles.dayHead} role="columnheader" aria-label={longDay.format(day)}>
              <button type="button" className={styles.dayTitle} onClick={() => onOpenDay(day)}>
                <span className={styles.weekday}>{shortWeekday.format(day)}</span>
                <span className={`${styles.dayNumber} ${today ? styles.today : ""}`}>{day.getDate()}</span>
              </button>
              <div className={styles.allDay}>
                {allDay.slice(0, ALL_DAY_SHOWN).map((e) => (
                  <button key={e.id} type="button" className={`${styles.chip} ${e.declined ? styles.declined : ""} ${e.id === selectedId ? styles.selected : ""}`} onClick={() => onSelect(e)} title={e.title}>
                    {e.title || "Sem título"}
                  </button>
                ))}
                {allDay.length > ALL_DAY_SHOWN && (
                  <button type="button" className={styles.more} onClick={() => onOpenDay(day)}>{`+${allDay.length - ALL_DAY_SHOWN} mais`}</button>
                )}
              </div>
            </div>
          );
        })}
      </div>
      <div className={styles.gridBody} ref={scroller}>
        <div className={styles.gridInner} style={{ height: 24 * HOUR_HEIGHT }}>
          <div className={styles.gutter}>
            {HOURS.map((h) => (
              <div key={h} className={styles.hourLabel} style={{ height: HOUR_HEIGHT }}>
                {h === 0 ? "" : `${String(h).padStart(2, "0")}:00`}
              </div>
            ))}
          </div>
          {days.map((day) => {
            const timed = eventsOnDay(events, day).filter((e) => !e.all_day);
            const byId = new Map(timed.map((e) => [e.id, e]));
            const placements = place(timed.map((e) => segmentOn(e, day)).filter((s) => s !== null));
            const minutes = now.getHours() * 60 + now.getMinutes();
            return (
              <div key={day.toISOString()} className={styles.column} data-day={startOfDay(day).getTime()}>
                {HOURS.map((h) => (
                  <div key={h} className={styles.hourLine} style={{ top: h * HOUR_HEIGHT }} />
                ))}
                {sameDay(day, now) && <div className={styles.nowLine} style={{ top: (minutes / 60) * HOUR_HEIGHT }} aria-hidden />}
                {placements.map((p) => {
                  const e = byId.get(p.id)!;
                  return (
                    <button
                      key={e.id}
                      type="button"
                      className={`${styles.block} ${e.declined ? styles.declined : ""} ${e.id === selectedId ? styles.selected : ""}`}
                      style={{
                        top: (p.startMinute / 60) * HOUR_HEIGHT,
                        height: Math.max(14, ((p.endMinute - p.startMinute) / 60) * HOUR_HEIGHT - 1),
                        left: `${(p.column / p.columns) * 100}%`,
                        width: `calc(${(p.span / p.columns) * 100}% - 2px)`,
                      }}
                      onClick={() => onSelect(e)}
                      title={`${e.title}\n${clockLabel(e.start)}–${clockLabel(e.end)}`}
                    >
                      <span className={styles.blockTitle}>{e.title || "Sem título"}</span>
                      <span className={styles.blockTime}>{clockLabel(e.start)}</span>
                    </button>
                  );
                })}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

export const weekDays = (start: Date) => Array.from({ length: 7 }, (_, i) => addDays(start, i));
