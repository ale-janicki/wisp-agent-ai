export const ANSI16: readonly string[] = [
  "#4B5263", "#F2555A", "#5BD66E", "#F5B83D", "#61AFEF", "#C678DD", "#4FD1C5", "#C9CDD6",
  "#7A8294", "#FF7B80", "#86E895", "#FFD068", "#8CC8FF", "#DDA0F0", "#7FE8DD", "#FFFFFF",
];

export const TERMINAL_BACKGROUND = "#1a1b1e";
export const TERMINAL_FOREGROUND = "#f2f2f3";
export const TERMINAL_ACCENT = "#a3d65c";

export function paletteColor(index: number): string {
  if (index < 16) return ANSI16[Math.max(0, index)] ?? ANSI16[0]!;
  if (index < 232) {
    const n = index - 16;
    const level = (v: number) => (v === 0 ? 0 : 55 + v * 40);
    const hex = (v: number) => level(v).toString(16).padStart(2, "0");
    return `#${hex(Math.floor(n / 36))}${hex(Math.floor(n / 6) % 6)}${hex(n % 6)}`;
  }
  const grey = 8 + (Math.min(index, 255) - 232) * 10;
  const h = grey.toString(16).padStart(2, "0");
  return `#${h}${h}${h}`;
}
