import { useState } from "react";
import type { PendingPermission } from "../../state/chat";
import { pretty } from "./format";
import styles from "./PermissionCard.module.css";

type Props = {
  request: PendingPermission;
  queued: number;
  onAnswer: (allow: boolean, always?: boolean) => void;
};

const isShell = (tool: string) => tool === "Bash" || tool === "PowerShell";

export function PermissionCard({ request, queued, onAnswer }: Props) {
  const [expanded, setExpanded] = useState(false);
  const [seenFull, setSeenFull] = useState(false);
  const locked = request.requiresExpansion !== false && !seenFull;
  const asker = request.asker ?? "Claude";
  const summary = request.summary ?? `usar ${request.toolName}`;
  const lockedLabel = isShell(request.toolName) ? "comando longo — veja inteiro" : "veja o conteúdo inteiro";
  const lockedHelp = "Abra o comando inteiro antes de permitir";
  const rules = request.persistRules ?? [];

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
      <div className={styles.summary} title={summary}>
        O {asker} quer <span className={styles.tool}>{summary}</span>
      </div>
      <button type="button" className={locked ? styles.lockedToggle : styles.toggle} onClick={toggle} aria-expanded={expanded}>
        {locked ? `⚠ ${lockedLabel}` : "detalhes"} {expanded ? "⌄" : "›"}
      </button>
      {expanded && <pre className={styles.detail}>{request.detail ?? pretty(request.input)}</pre>}
      {request.canPersist === true && rules.length > 0 && (
        <div className={styles.saves}>
          <span>Sempre permitir salva:</span>
          <ul>
            {rules.map((rule, i) => (
              <li key={i}>
                <code>{rule}</code> em {request.persistWhere?.[i] ?? "configurações do Claude"}
              </li>
            ))}
          </ul>
        </div>
      )}
      <div className={styles.actions}>
        <button
          type="button"
          className={styles.allow}
          disabled={locked}
          title={locked ? lockedHelp : ""}
          onClick={() => onAnswer(true)}
        >
          Permitir
        </button>
        {request.canPersist === true && (
          <button
            type="button"
            className={styles.always}
            disabled={locked}
            title={locked ? lockedHelp : `Salva no Claude: ${rules.join(", ")}`}
            onClick={() => onAnswer(true, true)}
          >
            Sempre permitir
          </button>
        )}
        <button type="button" className={styles.deny} onClick={() => onAnswer(false)}>
          Negar
        </button>
      </div>
    </div>
  );
}
