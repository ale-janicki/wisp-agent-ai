import type { RateWindow, UsageWindows } from "../api/types";

export type Severity = "normal" | "warning" | "critical";
export type UsageRow =
  | { kind: "session" | "week"; state: "used"; percent: number; resetsAt: number | null; severity: Severity }
  | { kind: "session" | "week"; state: "renewed" };

export const severityOf = (utilization: number): Severity =>
  utilization >= 0.9 ? "critical" : utilization >= 0.75 ? "warning" : "normal";

function row(kind: "session" | "week", window: RateWindow | null, nowSeconds: number): UsageRow {
  if (!window) return { kind, state: "used", percent: 0, resetsAt: null, severity: "normal" };
  if (window.resets_at !== null && window.resets_at <= nowSeconds) return { kind, state: "renewed" };
  return {
    kind,
    state: "used",
    percent: Math.round(window.utilization * 100),
    resetsAt: window.resets_at,
    severity: severityOf(window.utilization),
  };
}

export const usageRows = (usage: UsageWindows, nowSeconds: number): UsageRow[] => [
  row("session", usage.five_hour, nowSeconds),
  row("week", usage.seven_day, nowSeconds),
];

export const rowLabel = (r: UsageRow): string => {
  const name = r.kind === "session" ? "Sessão" : "Semana";
  return r.state === "used" ? `${name} ${r.percent}%` : `${name} renovado`;
};

export function rowDetail(r: UsageRow): string | null {
  if (r.state !== "used" || r.resetsAt === null) return null;
  const date = new Date(r.resetsAt * 1000);
  const hours = date.toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" });
  if (r.kind === "session") return `renova ${hours}`;
  const day = date.toLocaleDateString("pt-BR", { weekday: "short" }).replace(".", "");
  return `renova ${day} ${hours}`;
}
