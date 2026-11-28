import { useRef } from "react";
import type { Divider, Tab } from "./layout";
import { Pane } from "./Pane";
import { useWorkspace } from "./hooks";
import type { TerminalStore } from "./store";
import styles from "./Pane.module.css";

type Props = { store: TerminalStore; tab: Tab; findFor: string | null; onCloseFind: () => void };

const pct = (value: number): string => `${value * 100}%`;

export function PaneArea({ store, tab, findFor, onCloseFind }: Props) {
  const { workspace } = store;
  useWorkspace(workspace);
  const area = useRef<HTMLDivElement>(null);
  const frames = tab.frames;
  const split = Object.keys(frames).length > 1;

  const drag = (divider: Divider, event: React.PointerEvent<HTMLDivElement>) => {
    const box = area.current?.getBoundingClientRect();
    if (!box) return;
    event.preventDefault();
    const target = event.currentTarget;
    target.setPointerCapture(event.pointerId);
    const move = (e: PointerEvent) => workspace.resize(divider.path, divider.ratioAt({ x: (e.clientX - box.left) / box.width, y: (e.clientY - box.top) / box.height }));
    const stop = () => {
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", stop);
      target.removeEventListener("pointercancel", stop);
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", stop);
    target.addEventListener("pointercancel", stop);
  };

  return (
    <div className={styles.area} ref={area}>
      {tab.sessions
        .filter((id) => frames[id])
        .map((id) => {
          const session = workspace.session(id);
          const rect = frames[id]!;
          if (!session) return null;
          return (
            <div key={id} className={styles.frame} style={{ left: pct(rect.x), top: pct(rect.y), width: pct(rect.w), height: pct(rect.h) }}>
              <Pane
                store={store}
                session={session}
                focused={id === tab.focused}
                split={split}
                findOpen={findFor === id}
                onCloseFind={onCloseFind}
                onFocus={() => id !== tab.focused && workspace.select(id)}
              />
            </div>
          );
        })}
      {tab.dividers.map((divider) => {
        const horizontal = divider.axis === "horizontal";
        const at = horizontal ? divider.bounds.x + divider.bounds.w * divider.ratio : divider.bounds.y + divider.bounds.h * divider.ratio;
        const style = horizontal
          ? { left: pct(at), top: pct(divider.bounds.y), height: pct(divider.bounds.h) }
          : { top: pct(at), left: pct(divider.bounds.x), width: pct(divider.bounds.w) };
        return (
          <div
            key={divider.path.join("-") || "root"}
            className={`${styles.divider} ${horizontal ? styles.dividerH : styles.dividerV}`}
            style={style}
            role="separator"
            aria-orientation={horizontal ? "vertical" : "horizontal"}
            onPointerDown={(event) => drag(divider, event)}
          />
        );
      })}
    </div>
  );
}
