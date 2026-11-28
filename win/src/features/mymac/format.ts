const UNITS = ["B", "KB", "MB", "GB", "TB", "PB"];

function decimal(value: number, digits: number): string {
  let text = value.toFixed(digits).replace(".", ",");
  if (digits > 0 && text.endsWith("," + "0".repeat(digits))) text = text.slice(0, -(digits + 1));
  return text;
}

export function bytes(count: number, binary = false): string {
  const base = binary ? 1024 : 1000;
  let value = count;
  let index = 0;
  while (value >= base && index < UNITS.length - 1) {
    value /= base;
    index += 1;
  }
  if (index === 0) return `${Math.round(count)} B`;
  if (Math.round(value * 10) / 10 >= base && index < UNITS.length - 1) {
    value /= base;
    index += 1;
  }
  return `${decimal(value, value < 100 ? 1 : 0)} ${UNITS[index]}`;
}

export const rate = (perSecond: number) => `${bytes(perSecond)}/s`;

export function percent(fraction: number): string {
  const clamped = Math.min(1, Math.max(0, Number.isFinite(fraction) ? fraction : 0));
  return `${Math.round(clamped * 100)}%`;
}

export function processCpu(value: number): string {
  const safe = Math.max(0, Number.isFinite(value) ? value : 0);
  return `${decimal(safe, safe < 100 ? 1 : 0)}%`;
}

export const celsius = (value: number) => `${Math.round(value)} °C`;

export function duration(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const days = Math.floor(total / 86_400);
  const hours = Math.floor((total % 86_400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (days > 0) return `${days} d ${hours} h`;
  if (hours > 0) return `${hours} h ${String(minutes).padStart(2, "0")} min`;
  if (minutes > 0) return `${minutes} min`;
  return `${total} s`;
}
