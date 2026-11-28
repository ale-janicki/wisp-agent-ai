import { useEffect, useRef } from "react";
import type { Completion } from "./completion";
import styles from "./Pane.module.css";

const ICON: Record<Completion["kind"], string> = { dir: "▸", file: "·", exec: "›", builtin: "⌘" };

type Props = {
  items: Completion[];
  selected: number;
  header?: string;
  onPick: (index: number) => void;
};

export function CompletionMenu({ items, selected, header, onPick }: Props) {
  const list = useRef<HTMLUListElement>(null);
  useEffect(() => {
    list.current?.querySelector<HTMLElement>('[aria-selected="true"]')?.scrollIntoView?.({ block: "nearest" });
  }, [selected, items]);
  return (
    <div className={styles.menuList} role="listbox" aria-label={header ?? "Sugestões"}>
      {header && <div className={styles.menuHeader}>{header}</div>}
      <ul ref={list}>
        {items.map((item, i) => (
          <li
            key={`${item.insertText}-${i}`}
            role="option"
            aria-selected={i === selected}
            data-kind={item.kind}
            onMouseDown={(event) => {
              event.preventDefault();
              onPick(i);
            }}
          >
            <span className={styles.menuIcon}>{ICON[item.kind]}</span>
            <span className={styles.menuText}>{item.display}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
