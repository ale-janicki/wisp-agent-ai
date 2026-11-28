import { useEffect, useMemo, useRef, useState, type KeyboardEvent } from "react";
import { applyCompletion, completionAt, matchTags, type CompletionContext } from "./completion";
import { rank } from "./rank";
import type { NoteSummary } from "./types";
import styles from "./Editor.module.css";

type Props = {
  text: string;
  readOnly: boolean;
  notes: NoteSummary[];
  tags: Record<string, number>;
  focusLine?: number;
  onChange: (text: string) => void;
};

type Suggestion = { label: string; insert: string };

export function Editor({ text, readOnly, notes, tags, focusLine, onChange }: Props) {
  const area = useRef<HTMLTextAreaElement>(null);
  const [context, setContext] = useState<CompletionContext | null>(null);
  const [active, setActive] = useState(0);
  const pending = useRef<number | null>(null);

  useEffect(() => {
    const node = area.current;
    if (!node || focusLine === undefined) return;
    const offset = text.split("\n").slice(0, focusLine).join("\n").length + (focusLine > 0 ? 1 : 0);
    node.focus();
    node.setSelectionRange(offset, offset);
    node.scrollTop = Math.max(0, focusLine * 19 - node.clientHeight / 3);
  }, [focusLine]);

  useEffect(() => {
    if (pending.current !== null && area.current) {
      area.current.setSelectionRange(pending.current, pending.current);
      pending.current = null;
    }
  });

  const suggestions = useMemo<Suggestion[]>(() => {
    if (!context) return [];
    if (context.kind === "tag") return matchTags(context.query, tags).map((tag) => ({ label: `#${tag}`, insert: tag }));
    return rank(context.query, notes, 8).map((r) => {
      const note = notes.find((n) => n.path === r.path);
      const name = note?.link ?? r.title;
      return { label: r.alias ? `${r.title} (${r.alias})` : r.title, insert: r.alias ? `${name}|${r.alias}` : name };
    });
  }, [context, notes, tags]);

  const refresh = (value: string, cursor: number) => {
    setContext(completionAt(value, cursor));
    setActive(0);
  };

  const accept = (suggestion: Suggestion) => {
    if (!context) return;
    const next = applyCompletion(text, context, suggestion.insert);
    pending.current = next.cursor;
    onChange(next.text);
    setContext(null);
  };

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (!context || suggestions.length === 0) return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      setActive((i) => (i + (event.key === "ArrowDown" ? 1 : suggestions.length - 1)) % suggestions.length);
    } else if (event.key === "Enter" || event.key === "Tab") {
      event.preventDefault();
      accept(suggestions[active] ?? suggestions[0]!);
    } else if (event.key === "Escape") {
      event.stopPropagation();
      setContext(null);
    }
  };

  return (
    <div className={styles.wrap}>
      <textarea
        ref={area}
        className={styles.area}
        aria-label="Texto da nota"
        value={text}
        readOnly={readOnly}
        spellCheck={false}
        onChange={(e) => {
          onChange(e.target.value);
          refresh(e.target.value, e.target.selectionStart);
        }}
        onKeyDown={onKeyDown}
        onClick={(e) => refresh(text, e.currentTarget.selectionStart)}
        onBlur={() => setContext(null)}
      />
      {context && suggestions.length > 0 && (
        <ul className={styles.popup} role="listbox" aria-label="Sugestões">
          {suggestions.map((s, i) => (
            <li key={s.label + i} role="option" aria-selected={i === active} className={i === active ? styles.activeOption : undefined}>
              <button type="button" onMouseDown={(e) => e.preventDefault()} onClick={() => accept(s)}>
                {s.label}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
