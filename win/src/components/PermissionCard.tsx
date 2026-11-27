import { useState } from "react";
import type { PendingPermission } from "../state/chat";
import { pretty } from "./format";
import styles from "./PermissionCard.module.css";

type Props = {
  request: PendingPermission;
  queued: number;
  onAnswer: (allow: boolean) => void;
};

export function PermissionCard({ request, queued, onAnswer }: Props) {
  const [expanded, setExpanded] = useState(false);
  const [seenFull, setSeenFull] = useState(false);
  const locked = !seenFull;

  const toggle = () => {
    if (!expanded) setSeenFull(true);
    setExpanded(!expanded);
  };

  return (
    <div className={styles.card} role="group" aria-label="Pedido de permissão">
      <div className={styles.head}>
        <span className={styles.dot} aria-hidden />
        <span className={styles.step}>esperando tua aprovação</span>
        {queued > 0 && <span className={styles.queue}>+{queued} na fila</span>}
      </div>
      <div className={styles.summary}>
        O Wisp quer usar <span className={styles.tool}>{request.toolName}</span>
      </div>
      <button type="button" className={locked ? styles.lockedToggle : styles.toggle} onClick={toggle} aria-expanded={expanded}>
        {locked ? "veja o conteúdo inteiro" : "detalhes"} {expanded ? "⌄" : "›"}
      </button>
      {expanded && <pre className={styles.detail}>{pretty(request.input)}</pre>}
      <div className={styles.actions}>
        <button
          type="button"
          className={styles.allow}
          disabled={locked}
          title={locked ? "Abra o conteúdo inteiro antes de permitir" : ""}
          onClick={() => onAnswer(true)}
        >
          Permitir
        </button>
        <button type="button" className={styles.deny} onClick={() => onAnswer(false)}>
          Negar
        </button>
      </div>
    </div>
  );
}
