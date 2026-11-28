import { useState } from "react";
import type { ToolEntry } from "../../state/chat";
import { pretty } from "./format";
import styles from "./ToolBlock.module.css";

export function ToolBlock({ entry }: { entry: ToolEntry }) {
  const [open, setOpen] = useState(false);
  const { use, result } = entry;
  const failed = result?.is_error === true;
  const state = !result ? "rodando" : failed ? "erro" : "ok";
  return (
    <div className={styles.tool}>
      <button type="button" className={styles.head} aria-expanded={open} onClick={() => setOpen(!open)}>
        <span className={`${styles.dot} ${failed ? styles.err : result ? styles.ok : styles.busy}`} aria-hidden />
        <span className={styles.name}>{use.name}</span>
        <span className={styles.state}>{state}</span>
        <span className={`${styles.chevron} ${open ? styles.open : ""}`} aria-hidden>
          ›
        </span>
      </button>
      {open && (
        <div className={styles.body}>
          <div className={styles.cap}>entrada</div>
          <pre>{pretty(use.input)}</pre>
          {result && (
            <>
              <div className={styles.cap}>resultado</div>
              <pre>{pretty(result.content)}</pre>
            </>
          )}
        </div>
      )}
    </div>
  );
}
