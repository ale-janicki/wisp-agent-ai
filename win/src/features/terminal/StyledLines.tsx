import { memo, type CSSProperties } from "react";
import { paletteColor, TERMINAL_BACKGROUND, TERMINAL_FOREGROUND } from "./palette";
import type { CellStyle, StyledLine, TermColor } from "./styled";
import styles from "./StyledLines.module.css";

const resolve = (color: TermColor, fallback: string): string => (color === null ? fallback : typeof color === "number" ? paletteColor(color) : color);

export function cssFor(style: CellStyle): CSSProperties {
  let fg = resolve(style.fg, TERMINAL_FOREGROUND);
  let bg = style.bg === null ? undefined : resolve(style.bg, TERMINAL_BACKGROUND);
  if (style.inverse) {
    const swapped = fg;
    fg = bg ?? TERMINAL_BACKGROUND;
    bg = swapped;
  }
  const css: CSSProperties = {};
  if (style.fg !== null || style.inverse) css.color = fg;
  if (bg !== undefined) css.backgroundColor = bg;
  if (style.bold) css.fontWeight = 700;
  if (style.dim) css.opacity = 0.6;
  if (style.italic) css.fontStyle = "italic";
  const decorations = [style.underline ? "underline" : "", style.strike ? "line-through" : ""].filter(Boolean).join(" ");
  if (decorations) css.textDecoration = decorations;
  return css;
}

const isDefault = (style: CellStyle): boolean => Object.keys(cssFor(style)).length === 0;

const Line = memo(function Line({ line }: { line: StyledLine }) {
  if (line.text === "") return <div className={styles.line}>{"​"}</div>;
  if (line.runs.length === 0) return <div className={styles.line}>{line.text}</div>;
  return (
    <div className={styles.line}>
      {line.runs.map((run, i) =>
        isDefault(run.style) ? line.text.slice(run.start, run.end) : (
          <span key={i} style={cssFor(run.style)}>
            {line.text.slice(run.start, run.end)}
          </span>
        ),
      )}
    </div>
  );
});

export function StyledLines({ lines }: { lines: readonly StyledLine[] }) {
  return (
    <div className={styles.lines}>
      {lines.map((line, i) => (
        <Line key={i} line={line} />
      ))}
    </div>
  );
}
