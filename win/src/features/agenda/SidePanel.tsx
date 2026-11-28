import { useRichApi } from "../home/richApi";
import type { Status } from "./types";
import styles from "./AgendaTab.module.css";

export function SidePanel({ status, reload }: { status: Status; reload: () => Promise<unknown> }) {
  const api = useRichApi("agenda");
  return (
    <aside className={styles.side} aria-label="Calendários e lembretes">
      <section>
        <div className={styles.caption}>Calendários</div>
        <div className={styles.account}>
          <span className={styles.accountName}>{status.email}</span>
          <button type="button" className={styles.pill} onClick={() => void api.post("/signout").then(reload)}>
            Desconectar
          </button>
        </div>
      </section>
      <section>
        <div className={styles.caption}>Lembretes de hoje</div>
        <div className={styles.caption}>Nada para hoje</div>
      </section>
    </aside>
  );
}
