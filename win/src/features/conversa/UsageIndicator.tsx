import type { UsageWindows } from "../../api/types";
import { rowDetail, rowLabel, usageRows } from "../../state/usage";
import styles from "./UsageIndicator.module.css";

export function UsageIndicator({ usage, now = Date.now() / 1000 }: { usage: UsageWindows | null; now?: number }) {
  if (!usage || (!usage.five_hour && !usage.seven_day)) return null;
  const rows = usageRows(usage, now);
  const session = rows[0]!;
  const detail = rowDetail(session);
  const week = rows[1]!;
  return (
    <span
      className={`${styles.usage} ${session.state === "used" ? styles[session.severity] : ""}`}
      title={[rowLabel(session), detail, usage.seven_day ? rowLabel(week) : null].filter(Boolean).join(" · ")}
      role="status"
    >
      {rowLabel(session)}
      {detail && <span className={styles.detail}> · {detail}</span>}
    </span>
  );
}
