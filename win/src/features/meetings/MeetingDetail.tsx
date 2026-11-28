import { useEffect, useState } from "react";
import { Markdown } from "../../components/Markdown";
import { fetchAudioUrl } from "./api";
import { LineRow } from "./LiveView";
import { WebhookCard } from "./WebhookCard";
import type { Meetings } from "./useMeetings";
import { failureLine, primaryAction, statusLine } from "./view";
import styles from "./Meetings.module.css";

const STAGES: Record<string, string> = {
  transcribing: "Transcrevendo",
  refining: "Revisando a transcrição",
  writing_note: "Gerando a nota",
};

export function MeetingDetail({ m }: { m: Meetings }) {
  const { detail, selected } = m;
  const [tab, setTab] = useState<"note" | "transcript">("note");
  const [menu, setMenu] = useState(false);
  const [audio, setAudio] = useState<string | null>(null);
  const [audioError, setAudioError] = useState<string | null>(null);

  useEffect(() => {
    setTab("note");
    setMenu(false);
    setAudio((old) => {
      if (old) URL.revokeObjectURL(old);
      return null;
    });
    setAudioError(null);
  }, [selected]);

  if (!detail || !selected) return <div className={styles.empty}>Carregando…</div>;
  const id = selected;
  const action = primaryAction(detail);
  const failure = failureLine(detail);
  const job = detail.job ?? m.state?.processing[id] ?? null;
  const progress = job?.stage ? `${STAGES[job.stage] ?? "Processando"}${job.fraction !== null && job.fraction !== undefined ? ` ${Math.floor(job.fraction * 100)}%` : "…"}` : null;
  const offer = detail.webhook_offer;

  const runPrimary = () => {
    if (action.kind === "generate") void m.generateNote(id);
    else if (action.kind === "cancel") void m.cancelNote(id);
    else if (action.kind === "saveBrain") void m.saveToBrain(id);
    else if (action.kind === "openBrain") void m.openBrainNote(id);
  };

  const copy = () => {
    const text = tab === "note" && detail.note ? detail.note : detail.lines.map((l) => `[${l.time}] ${l.speaker}: ${l.text}`).join("\n");
    void navigator.clipboard?.writeText(text);
    setMenu(false);
  };

  const listen = async () => {
    try {
      setAudio(await fetchAudioUrl(m.info, id, m.fetchImpl));
    } catch (error) {
      setAudioError(error instanceof Error ? error.message : String(error));
    }
  };

  return (
    <article className={styles.detail}>
      <header className={styles.detailHead}>
        <div className={styles.detailTitles}>
          <h2 className={styles.detailTitle}>{detail.row.title}</h2>
          <p className={styles.rowMeta}>{statusLine(detail.row)}</p>
        </div>
        {action.kind !== "none" && (
          <button type="button" className={styles.primary} onClick={runPrimary}>
            {action.label}
          </button>
        )}
        <div className={styles.menuWrap}>
          <button type="button" className={styles.ghost} onClick={() => setMenu(!menu)} aria-haspopup="menu" aria-expanded={menu} aria-label="Mais ações">
            …
          </button>
          {menu && (
            <div className={styles.menu} role="menu">
              <button type="button" role="menuitem" onClick={copy}>
                Copiar
              </button>
              <button type="button" role="menuitem" onClick={() => { setMenu(false); void m.openFolder(id); }}>
                Abrir pasta
              </button>
              {action.kind !== "saveBrain" && !detail.brain.opens_note && detail.note !== null && (
                <button type="button" role="menuitem" onClick={() => { setMenu(false); void m.saveToBrain(id); }}>
                  Salvar no brain
                </button>
              )}
              {detail.brain.opens_note && action.kind !== "openBrain" && (
                <button type="button" role="menuitem" onClick={() => { setMenu(false); void m.openBrainNote(id); }}>
                  Abrir no brain
                </button>
              )}
              {detail.note !== null && (
                <button type="button" role="menuitem" onClick={() => { setMenu(false); void m.generateNote(id); }}>
                  Gerar nota de novo
                </button>
              )}
              {detail.has_audio && (
                <button type="button" role="menuitem" onClick={() => { setMenu(false); void m.improve(id); }}>
                  Melhorar transcrição
                </button>
              )}
            </div>
          )}
        </div>
      </header>
      {progress && (
        <div className={styles.hintBox} role="status">
          {progress}
        </div>
      )}
      {failure && (
        <div className={styles.errorBox} role="alert" title={failure.tooltip}>
          <span>{failure.text}</span>
          {!detail.meta.brain_error || detail.meta.failure ? (
            <button type="button" className={styles.link} onClick={() => void m.retry(id)}>
              Tentar de novo
            </button>
          ) : (
            <button type="button" className={styles.link} onClick={() => void m.saveToBrain(id)}>
              Tentar de novo
            </button>
          )}
        </div>
      )}
      {(detail.meta.notice ?? detail.row.notice) && (
        <div className={styles.hintBox} role="note">
          <span>{detail.meta.notice ?? detail.row.notice}</span>
          {detail.has_audio && (
            <button type="button" className={styles.link} onClick={() => void m.improve(id)}>
              Melhorar transcrição
            </button>
          )}
        </div>
      )}
      {offer && <WebhookCard offer={offer} onAllow={() => void m.allowWebhook(id)} onDismiss={() => void m.dismissWebhook(id)} />}
      <div className={styles.tabs} role="tablist">
        <button type="button" role="tab" aria-selected={tab === "note"} className={tab === "note" ? styles.tabOn : styles.tab} onClick={() => setTab("note")}>
          Nota
        </button>
        <button type="button" role="tab" aria-selected={tab === "transcript"} className={tab === "transcript" ? styles.tabOn : styles.tab} onClick={() => setTab("transcript")}>
          Transcrição
        </button>
        {detail.has_audio && !audio && (
          <button type="button" className={styles.link} onClick={() => void listen()}>
            Ouvir a gravação
          </button>
        )}
      </div>
      {audioError && <div className={styles.errorText}>{audioError}</div>}
      {audio && <audio className={styles.audio} controls autoPlay src={audio} aria-label="Gravação" />}
      <div className={styles.body}>
        {tab === "note" ? (
          detail.note ? (
            <div className={styles.note}>
              <Markdown text={detail.note} />
            </div>
          ) : (
            <div className={styles.empty}>Sem nota ainda.</div>
          )
        ) : detail.lines.length === 0 ? (
          <div className={styles.empty}>Sem transcrição ainda.</div>
        ) : (
          <div className={styles.lines}>
            {detail.lines.map((line) => (
              <LineRow key={line.id} line={line} />
            ))}
          </div>
        )}
      </div>
    </article>
  );
}
