import { useState } from "react";
import { WaveformIcon } from "../../shell/icons";
import { LiveView } from "./LiveView";
import { MeetingDetail } from "./MeetingDetail";
import { MeetingList } from "./MeetingList";
import { ModelCard } from "./ModelCard";
import { PrepCard } from "./PrepCard";
import { RecorderBar } from "./RecorderBar";
import { SettingsPanel } from "./SettingsPanel";
import { WebhookCard } from "./WebhookCard";
import { useMeetings } from "./useMeetings";
import styles from "./Meetings.module.css";

export function MeetingsTab() {
  const m = useMeetings();
  const [settingsOpen, setSettingsOpen] = useState(false);
  const { state } = m;

  if (!state) {
    return (
      <div className={styles.tab}>
        <div className={styles.empty}>{m.toast ? m.toast.text : "Carregando…"}</div>
      </div>
    );
  }

  const busy = state.phase !== "idle";
  const offers = Object.values(state.webhook_offers).filter((o) => o.id !== m.selected);

  let right;
  if (busy) {
    right = (
      <LiveView
        state={state}
        lines={m.lines}
        brainSearch={m.settings?.brain_search ?? false}
        onBookmark={() => void m.bookmark()}
        onToggle={(changes) => void m.setCopilot(changes)}
        onDismissNudge={() => void m.dismissNudge()}
        onCheck={(id, done) => void m.toggleCheck(id, done)}
      />
    );
  } else if (settingsOpen) {
    right = <SettingsPanel m={m} onBack={() => setSettingsOpen(false)} />;
  } else if (m.selected) {
    right = <MeetingDetail m={m} />;
  } else {
    right = (
      <div className={styles.idle}>
        <WaveformIcon size={28} />
        <p className={styles.idleText}>Grave uma reunião: o Wisp transcreve, resume e guarda no brain.</p>
        <button type="button" className={styles.primary} onClick={() => void m.start()}>
          Começar a gravar
        </button>
        <PrepCard prep={state.copilot.prep} onPrepare={m.prepare} />
      </div>
    );
  }

  return (
    <div className={styles.tab}>
      <nav className={styles.column} aria-label="Reuniões">
        <RecorderBar
          state={state}
          onStart={() => void m.start()}
          onStop={() => void m.stop()}
          onPause={() => void m.pause()}
          onResume={() => void m.resume()}
          onSources={(sources) => void m.setSources(sources)}
        />
        <MeetingList
          rows={m.rows}
          selected={m.selected}
          recordingId={state.meeting}
          onSelect={(id) => {
            setSettingsOpen(false);
            m.select(id);
          }}
          onSettings={() => setSettingsOpen(!settingsOpen)}
          settingsOpen={settingsOpen}
        />
      </nav>
      <section className={styles.pane}>
        {state.message && (
          <div className={state.message.tone === "error" ? styles.errorBox : styles.hintBox} role={state.message.tone === "error" ? "alert" : "status"}>
            <span>{state.message.text}</span>
            <button type="button" className={styles.x} onClick={() => void m.dismissMessage()} aria-label="Dispensar">
              ×
            </button>
          </div>
        )}
        {m.toast && (
          <div className={m.toast.tone === "error" ? styles.errorBox : styles.hintBox} role="alert">
            <span>{m.toast.text}</span>
            <button type="button" className={styles.x} onClick={m.dismissToast} aria-label="Dispensar">
              ×
            </button>
          </div>
        )}
        {!settingsOpen && (
          <ModelCard
            models={m.models.items.filter((item) => item.role === "live")}
            attribution={m.models.attribution}
            onDownload={(id) => void m.downloadModel(id)}
            onCancel={(id) => void m.cancelModel(id)}
          />
        )}
        {offers.map((offer) => (
          <WebhookCard key={offer.id} offer={offer} onAllow={() => void m.allowWebhook(offer.id)} onDismiss={() => void m.dismissWebhook(offer.id)} />
        ))}
        <div className={styles.content}>{right}</div>
      </section>
    </div>
  );
}
