import type { Detail, Phase, Row } from "./types";

export function clock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const two = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${m}:${two(s)}`;
}

export const statusLine = (row: Row): string => `${row.date_text} · ${row.duration_text} · ${row.badge.label}`;

export function recordButton(phase: Phase, saving: number | null): { title: string; enabled: boolean } {
  switch (phase) {
    case "idle":
      return { title: "Gravar", enabled: true };
    case "starting":
      return { title: "Iniciando…", enabled: false };
    case "recording":
      return { title: "Parar", enabled: true };
    case "finishing":
      return { title: saving === null ? "Salvando…" : `Salvando ${Math.floor(Math.min(1, Math.max(0, saving)) * 100)}%`, enabled: false };
  }
}

export type Primary = { kind: "generate" | "cancel" | "openBrain" | "saveBrain" | "none"; label: string };

export function primaryAction(detail: Detail): Primary {
  const { meta, job, brain } = detail;
  if (job?.stage === "writing_note") return { kind: "cancel", label: "Cancelar nota" };
  const hasNote = detail.note !== null;
  const transcribed = meta.status === "transcribed" || meta.status === "failed";
  if (!hasNote && transcribed) return { kind: "generate", label: "Gerar nota" };
  if (!hasNote) return { kind: "none", label: "" };
  return brain.opens_note ? { kind: "openBrain", label: brain.label } : { kind: "saveBrain", label: brain.label };
}

export function failureLine(detail: Detail): { text: string; tooltip?: string } | null {
  const { failure, brain_error: brain, status } = detail.meta;
  if (failure) {
    return failure.startsWith("nota não gerada")
      ? { text: "A nota não foi gerada. Tente de novo.", tooltip: failure }
      : { text: failure, tooltip: status === "failed" ? undefined : failure };
  }
  return brain ? { text: brain } : null;
}

const PIN_THRESHOLD = 24;
export const shouldFollow = (distanceFromBottom: number): boolean => distanceFromBottom <= PIN_THRESHOLD;

export const meterFraction = (levels: { mic: number; system: number }): number =>
  Math.min(1, Math.max(0, levels.mic, levels.system));

export function sizeText(bytes: number): string {
  const mb = bytes / 1024 ** 2;
  return mb >= 1024 ? `${(mb / 1024).toFixed(1).replace(".", ",")} GB` : `${Math.round(mb)} MB`;
}
