import { useEffect, useState } from "react";
import { useOpenExternal } from "../home/external";
import { useRichApi } from "../home/richApi";
import type { Status } from "./types";
import styles from "./AgendaTab.module.css";

const CONSOLE = "https://console.cloud.google.com/apis/credentials";

export function ConnectGoogle({ status, reload }: { status: Status; reload: () => Promise<unknown> }) {
  const api = useRichApi("agenda");
  const openExternal = useOpenExternal();
  const [text, setText] = useState("");
  const [problem, setProblem] = useState<string | null>(null);
  const [connecting, setConnecting] = useState(status.connecting);
  useEffect(() => setConnecting(status.connecting), [status.connecting]);

  if (!status.storage) {
    return (
      <div className={styles.connect}>
        <p className={styles.message}>Guardar o login do Google só funciona no Windows.</p>
      </div>
    );
  }

  const save = async () => {
    setProblem(null);
    try {
      await api.put("/client", { credentials: text });
      setText("");
      await reload();
    } catch (error) {
      setProblem(error instanceof Error ? error.message : "Não consegui salvar as credenciais.");
    }
  };

  if (!status.has_client) {
    return (
      <div className={styles.connect}>
        <h3 className={styles.connectTitle}>Conecte sua conta do Google</h3>
        <ol className={styles.steps}>
          <li>
            No Google Cloud Console, crie um projeto e ative a Google Calendar API.{" "}
            <button type="button" className={styles.pill} onClick={() => openExternal(CONSOLE)}>
              Abrir Google Cloud
            </button>
          </li>
          <li>Crie um cliente OAuth do tipo App para computador e baixe o credentials.json.</li>
          <li>Cole o conteúdo do arquivo aqui e salve; ele fica protegido para a sua conta do Windows.</li>
        </ol>
        <textarea
          className={styles.credentials}
          aria-label="Conteúdo do credentials.json"
          placeholder='{"installed": {"client_id": "…", "client_secret": "…"}}'
          value={text}
          onChange={(e) => setText(e.target.value)}
          rows={4}
        />
        {problem && (
          <div className={styles.error} role="alert">
            {problem}
          </div>
        )}
        <div>
          <button type="button" className={`${styles.pill} ${styles.accent}`} disabled={!text.trim()} onClick={() => void save()}>
            Salvar credenciais
          </button>
        </div>
      </div>
    );
  }

  const connect = async () => {
    setProblem(null);
    try {
      const next = await api.post<Partial<Status>>("/connect");
      if (typeof next?.connecting === "boolean") setConnecting(next.connecting);
    } catch (error) {
      setProblem(error instanceof Error ? error.message : null);
    }
    await reload();
  };

  return (
    <div className={styles.connect}>
      <div className={styles.connectRow}>
        <button type="button" className={styles.connectButton} disabled={connecting} onClick={() => void connect()}>
          <span className={styles.connectName}>{connecting ? "Conectando ao Google…" : "Conectar Google"}</span>
          <span className={styles.caption}>
            {connecting ? "Termine o login no navegador; o Wisp espera até 5 minutos." : "Seus eventos, convites e respostas, direto do Google Agenda."}
          </span>
        </button>
        {connecting && (
          <button type="button" className={styles.pill} onClick={() => void api.post("/cancel").then(reload)}>
            Cancelar
          </button>
        )}
      </div>
      {(problem ?? status.error) && (
        <div className={styles.error} role="alert">
          {problem ?? status.error}
        </div>
      )}
      {!connecting && (
        <button type="button" className={styles.linkButton} onClick={() => void api.delete("/client").then(reload)}>
          Trocar credenciais
        </button>
      )}
    </div>
  );
}
