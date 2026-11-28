export type TermColor = number | string | null;

export type CellStyle = {
  fg: TermColor;
  bg: TermColor;
  bold: boolean;
  dim: boolean;
  italic: boolean;
  underline: boolean;
  inverse: boolean;
  strike: boolean;
};

export type StyledRun = { start: number; end: number; style: CellStyle };
export type StyledLine = { text: string; runs: StyledRun[] };

export const PLAIN: CellStyle = { fg: null, bg: null, bold: false, dim: false, italic: false, underline: false, inverse: false, strike: false };

export const sameStyle = (a: CellStyle, b: CellStyle): boolean =>
  a.fg === b.fg &&
  a.bg === b.bg &&
  a.bold === b.bold &&
  a.dim === b.dim &&
  a.italic === b.italic &&
  a.underline === b.underline &&
  a.inverse === b.inverse &&
  a.strike === b.strike;

export const isPlain = (style: CellStyle): boolean => sameStyle(style, PLAIN);

export function trimLine(line: StyledLine): StyledLine {
  const text = line.text.replace(/[ \t]+$/, "");
  if (text.length === line.text.length) return line;
  const runs: StyledRun[] = [];
  for (const run of line.runs) {
    if (run.start >= text.length) break;
    runs.push({ ...run, end: Math.min(run.end, text.length) });
  }
  return { text, runs };
}

export function appendLine(line: StyledLine, other: StyledLine): StyledLine {
  const shift = line.text.length;
  const runs = line.runs.slice();
  for (const run of other.runs) {
    const moved = { start: run.start + shift, end: run.end + shift, style: run.style };
    const last = runs[runs.length - 1];
    if (last && last.end === moved.start && sameStyle(last.style, moved.style)) runs[runs.length - 1] = { ...last, end: moved.end };
    else runs.push(moved);
  }
  return { text: line.text + other.text, runs };
}
