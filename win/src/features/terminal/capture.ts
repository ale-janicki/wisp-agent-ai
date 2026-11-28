import { appendLine, PLAIN, sameStyle, trimLine, type CellStyle, type StyledLine, type StyledRun, type TermColor } from "./styled";

export type BufferCellLike = {
  getChars(): string;
  getWidth(): number;
  getFgColor(): number;
  getBgColor(): number;
  isFgRGB(): boolean;
  isBgRGB(): boolean;
  isFgPalette(): boolean;
  isBgPalette(): boolean;
  isBold(): number;
  isDim(): number;
  isItalic(): number;
  isUnderline(): number;
  isInverse(): number;
  isStrikethrough(): number;
};
export type BufferLineLike = {
  readonly isWrapped: boolean;
  readonly length: number;
  getCell(x: number, cell?: BufferCellLike): BufferCellLike | undefined;
};
export type BufferLike = {
  readonly length: number;
  getLine(y: number): BufferLineLike | undefined;
};

const hex = (value: number): string => `#${(value & 0xffffff).toString(16).padStart(6, "0")}`;

function color(rgb: boolean, palette: boolean, value: number): TermColor {
  if (rgb) return hex(value);
  return palette ? value : null;
}

function styleOf(cell: BufferCellLike): CellStyle {
  const fg = color(cell.isFgRGB(), cell.isFgPalette(), cell.getFgColor());
  const bg = color(cell.isBgRGB(), cell.isBgPalette(), cell.getBgColor());
  const bold = !!cell.isBold();
  const dim = !!cell.isDim();
  const italic = !!cell.isItalic();
  const underline = !!cell.isUnderline();
  const inverse = !!cell.isInverse();
  const strike = !!cell.isStrikethrough();
  if (fg === null && bg === null && !bold && !dim && !italic && !underline && !inverse && !strike) return PLAIN;
  return { fg, bg, bold, dim, italic, underline, inverse, strike };
}

function rowLine(row: BufferLineLike): StyledLine {
  let text = "";
  const runs: StyledRun[] = [];
  for (let x = 0; x < row.length; x++) {
    const cell = row.getCell(x);
    if (!cell || cell.getWidth() === 0) continue;
    const chars = cell.getChars() || " ";
    const style = styleOf(cell);
    const last = runs[runs.length - 1];
    if (last && sameStyle(last.style, style)) last.end = text.length + chars.length;
    else runs.push({ start: text.length, end: text.length + chars.length, style });
    text += chars;
  }
  return { text, runs };
}

export function captureLines(buffer: BufferLike, from: number, to: number): StyledLine[] {
  const lines: StyledLine[] = [];
  const end = Math.min(to, buffer.length);
  for (let y = Math.max(0, from); y < end; y++) {
    const row = buffer.getLine(y);
    if (!row) continue;
    const line = rowLine(row);
    const previous = lines[lines.length - 1];
    if (row.isWrapped && previous) lines[lines.length - 1] = appendLine(previous, line);
    else lines.push(line);
  }
  return lines.map(trimLine);
}

export function plainText(lines: readonly StyledLine[]): string {
  const texts = lines.map((l) => l.text);
  while (texts.length > 0 && texts[texts.length - 1] === "") texts.pop();
  return texts.join("\n");
}
