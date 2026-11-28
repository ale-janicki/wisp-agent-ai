import { useState } from "react";
import { ModelCard } from "./ModelCard";
import type { Meetings } from "./useMeetings";
import styles from "./Meetings.module.css";

const limitText = (minutes: number) => (minutes % 60 === 0 ? `${minutes / 60} h` : `${minutes} min`);

export function SettingsPanel({ m, onBack }: { m: Meetings; onBack: () => void }) {
  const { settings, models } = m;
  const [url, setUrl] = useState("");
  const [secret, setSecret] = useState<string | null>(null);
  if (!settings) return <div className={styles.empty}>Carregando…</div>;
  const v = settings.values;
  const hook = settings.webhook;
  return (
    <div className={styles.settings}>
      <header className={styles.detailHead}>
        <h2 className={styles.detailTitle}>Ajustes das reuniões</h2>
        <button type="button" className={styles.ghost} onClick={onBack}>
          Voltar
        </button>
      </header>
      <label className={styles.field}>
        Idioma das reuniões
        <select className={styles.select} value={v.language} onChange={(e) => void m.putSettings({ language: e.target.value })}>
          {settings.languages.map((l) => (
            <option key={l.id} value={l.id}>
              {l.label}
            </option>
          ))}
        </select>
      </label>
      <label className={styles.field}>
        Revisão depois da chamada
        <select className={styles.select} value={v.postCallEngine} onChange={(e) => void m.putSettings({ postCallEngine: e.target.value })}>
          {settings.engines.map((e) => (
            <option key={e.id} value={e.id}>
              {e.label}
            </option>
          ))}
        </select>
      </label>
      <label className={styles.field}>
        Limite de gravação
        <select className={styles.select} value={v.limitMinutes} onChange={(e) => void m.putSettings({ limitMinutes: Number(e.target.value) })}>
          {settings.limit_choices.map((minutes) => (
            <option key={minutes} value={minutes}>
              {limitText(minutes)}
            </option>
          ))}
        </select>
      </label>
      <label className={styles.toggle}>
        <input type="checkbox" checked={v.autoSummary} onChange={(e) => void m.putSettings({ autoSummary: e.target.checked })} />
        Gerar o resumo sozinho quando a reunião acabar
      </label>
      <label className={styles.field}>
        Apagar a gravação depois de salva no brain
        <select className={styles.select} value={v.cleanupDays} onChange={(e) => void m.putSettings({ cleanupDays: Number(e.target.value) })}>
          <option value={0}>Nunca</option>
          {settings.cleanup_choices.map((days) => (
            <option key={days} value={days}>
              Depois de {days} dias
            </option>
          ))}
        </select>
      </label>
      <p className={styles.hint}>As gravações ficam em {settings.recordings_path}. A limpeza manda a pasta para a Lixeira.</p>
      <section className={styles.card} aria-label="Webhook">
        <h3 className={styles.cardTitle}>Webhook</h3>
        <label className={styles.toggle}>
          <input type="checkbox" checked={hook.enabled} onChange={(e) => void m.putWebhook({ enabled: e.target.checked })} />
          Oferecer o envio do resumo quando a reunião acabar
        </label>
        <p className={styles.hint}>
          {hook.url_set ? `Endereço salvo: ${hook.masked_url ?? "inválido"}` : "Nenhum endereço salvo."} O endereço fica criptografado no Windows, fora do
          arquivo de ajustes. Só https, em endereços públicos.
        </p>
        <div className={styles.actions}>
          <input className={styles.input} placeholder="https://…" aria-label="Endereço do webhook" value={url} onChange={(e) => setUrl(e.target.value)} />
          <button
            type="button"
            className={styles.ghost}
            disabled={!url.trim()}
            onClick={async () => {
              await m.putWebhook({ url });
              setUrl("");
            }}
          >
            Salvar endereço
          </button>
        </div>
        <label className={styles.toggle}>
          <input type="checkbox" checked={hook.signs} onChange={(e) => void m.putWebhook({ signs: e.target.checked })} />
          Assinar o envio
        </label>
        {hook.signs && hook.secret_set && (
          <div className={styles.actions}>
            <button type="button" className={styles.link} onClick={async () => setSecret(await m.revealSecret())}>
              Mostrar a chave
            </button>
            {secret && <code className={styles.mono}>{secret}</code>}
          </div>
        )}
      </section>
      <ModelCard
        models={models.items}
        attribution={models.attribution}
        onDownload={(id) => void m.downloadModel(id)}
        onCancel={(id) => void m.cancelModel(id)}
        onlyMissing={false}
      />
    </div>
  );
}
