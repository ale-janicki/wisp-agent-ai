import { useEffect, useState } from "react";
import type { TerminalBackend } from "./backend";
import { directoryLabel } from "./directory";
import { isDefaultBranch, parseGitStatus, type GitStatus } from "./git";
import styles from "./Pane.module.css";

type Props = {
  backend: Pick<TerminalBackend, "gitStatus">;
  directory: string;
  home: string;
  finishedKey: number | null;
};

export function ContextChips({ backend, directory, home, finishedKey }: Props) {
  const [git, setGit] = useState<{ directory: string; status: GitStatus | null } | null>(null);
  useEffect(() => {
    let alive = true;
    void backend
      .gitStatus(directory)
      .then((raw) => {
        if (alive) setGit({ directory, status: raw ? parseGitStatus(raw.porcelain, raw.shortstat) : null });
      })
      .catch(() => {
        if (alive) setGit({ directory, status: null });
      });
    return () => {
      alive = false;
    };
  }, [backend, directory, finishedKey]);

  const status = git && git.directory === directory ? git.status : null;
  return (
    <div className={styles.chips} aria-label="Contexto">
      <span className={styles.chip} title={directory}>
        {directoryLabel(directory, home)}
      </span>
      {status && (
        <span className={`${styles.chip} ${isDefaultBranch(status.branch) ? styles.chipAlert : styles.chipBranch}`} title="Branch">
          ⎇ {status.branch}
        </span>
      )}
      {status && status.changedFiles > 0 && (
        <span className={styles.chip} title="Arquivos alterados">
          <span className={styles.dirty}>● {status.changedFiles}</span> <span className={styles.added}>+{status.insertions}</span>{" "}
          <span className={styles.removed}>−{status.deletions}</span>
        </span>
      )}
    </div>
  );
}
