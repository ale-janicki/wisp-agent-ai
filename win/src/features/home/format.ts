const time = new Intl.DateTimeFormat("pt-BR", { hour: "2-digit", minute: "2-digit", hour12: false });
const weekday = new Intl.DateTimeFormat("pt-BR", { weekday: "short" });
const dayMonth = new Intl.DateTimeFormat("pt-BR", { day: "numeric", month: "short" });

export const clockTime = (d: Date) => time.format(d);
export const dayTime = (d: Date) => `${weekday.format(d).replace(".", "")} ${time.format(d)}`;

const SCALES: [number, string][] = [
  [1e9, "bi"],
  [1e6, "mi"],
  [1e3, "mil"],
];

export function tokens(count: number): string {
  const value = Math.max(0, count);
  let index = SCALES.findIndex(([size]) => value >= size);
  if (index < 0) return String(Math.trunc(value));
  let tenths = Math.round((value / SCALES[index]![0]) * 10) / 10;
  if (tenths >= 1000 && index > 0) {
    index -= 1;
    tenths = Math.round((value / SCALES[index]![0]) * 10) / 10;
  }
  const text = tenths.toFixed(1).replace(".", ",");
  return `${text.endsWith(",0") ? text.slice(0, -2) : text} ${SCALES[index]![1]}`;
}

export function age(capturedAtSeconds: number, nowMs = Date.now()): string {
  const seconds = nowMs / 1000 - capturedAtSeconds;
  if (seconds < 60) return "atualizado agora";
  if (seconds < 3600) return `atualizado há ${Math.floor(seconds / 60)} min`;
  if (seconds < 86_400) return `atualizado há ${Math.floor(seconds / 3600)} h`;
  return `atualizado há ${Math.floor(seconds / 86_400)} d`;
}

export function conversationDate(date: Date, now = new Date()): string {
  const sameDay = (a: Date, b: Date) => a.toDateString() === b.toDateString();
  const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
  if (sameDay(date, now)) return `hoje, ${time.format(date)}`;
  if (sameDay(date, yesterday)) return `ontem, ${time.format(date)}`;
  return `${dayMonth.format(date)}, ${time.format(date)}`;
}
