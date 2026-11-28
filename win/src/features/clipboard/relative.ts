const formatter = new Intl.RelativeTimeFormat("pt-BR", { style: "short", numeric: "auto" });

export function relative(epochSeconds: number, nowMs = Date.now()): string {
  const seconds = nowMs / 1000 - epochSeconds;
  if (seconds < 60) return "agora";
  if (seconds < 3600) return formatter.format(-Math.floor(seconds / 60), "minute");
  if (seconds < 86_400) return formatter.format(-Math.floor(seconds / 3600), "hour");
  return formatter.format(-Math.floor(seconds / 86_400), "day");
}
