import { useState } from "react";
import { features, featureById } from "../features/registry";
import { Sidebar } from "./Sidebar";
import { ShellContext, type ShellValue } from "./context";
import { useSelectedFeature } from "./useSelectedFeature";
import styles from "./PanelShell.module.css";

type Props = {
  value: Omit<ShellValue, "navigate">;
  windowed: boolean;
  onToggleWindow: () => void;
  status: { label: string; tone: "ok" | "busy" | "error" };
  onMouseEnter?: () => void;
  onMouseLeave?: () => void;
  registry?: typeof features;
};

export function PanelShell({ value, windowed, onToggleWindow, status, onMouseEnter, onMouseLeave, registry = features }: Props) {
  const [selected, select] = useSelectedFeature();
  const [railHovered, setRailHovered] = useState(false);
  const current = registry.find((f) => f.id === selected) ?? featureById(selected) ?? registry[0]!;
  const rail = current.hasListColumn === true;
  const expanded = rail && railHovered;

  const onSelect = (id: string) => {
    const next = registry.find((f) => f.id === id);
    if (!next) return;
    if (!(rail && next.hasListColumn)) setRailHovered(false);
    select(id);
  };

  const Content = current.Component;
  return (
    <ShellContext.Provider value={{ ...value, navigate: onSelect }}>
      <div
        className={styles.panel}
        data-windowed={windowed}
        data-testid="panel"
        onMouseEnter={onMouseEnter}
        onMouseLeave={onMouseLeave}
      >
        <div className={styles.slot} data-rail={rail}>
          <div
            className={styles.side}
            data-rail={rail}
            data-expanded={expanded}
            onMouseEnter={() => rail && setRailHovered(true)}
            onMouseLeave={() => setRailHovered(false)}
          >
            <Sidebar
              features={registry}
              selected={current.id}
              onSelect={onSelect}
              compact={rail && !expanded}
              windowed={windowed}
              onToggleWindow={onToggleWindow}
              status={status}
            />
          </div>
        </div>
        <main className={styles.content} aria-label={current.label}>
          <Content key={current.id} />
        </main>
      </div>
    </ShellContext.Provider>
  );
}

