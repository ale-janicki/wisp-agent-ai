import type { Copilot } from "./types";
import { clock } from "./view";
import styles from "./Meetings.module.css";

type Props = {
  copilot: Copilot;
  brainSearch: boolean;
  onToggle: (changes: Record<string, boolean>) => void;
  onDismissNudge: () => void;
  onCheck: (id: string, done: boolean) => void;
};

const percent = (part: number, whole: number) => (whole > 0 ? Math.round((100 * part) / whole) : 0);

export function CopilotPanel({ copilot, brainSearch, onToggle, onDismissNudge, onCheck }: Props) {
  const m = copilot.metrics;
  const spoken = m ? m.you.speaking_s + m.others.speaking_s : 0;
  return (
    <aside className={styles.side} aria-label="Copiloto">
      {copilot.nudge && (
        <div className={styles.nudge} role="status">
          <span>{copilot.nudge.text}</span>
          <button type="button" className={styles.x} onClick={onDismissNudge} aria-label="Dispensar aviso">
            ×
          </button>
        </div>
      )}
      <section className={styles.sideSection}>
        <h4 className={styles.sideTitle}>Conversa</h4>
        {m && spoken > 0 ? (
          <dl className={styles.metrics}>
            <dt>Tempo de fala</dt>
            <dd>
              Você {percent(m.you.speaking_s, spoken)}% · Outros {percent(m.others.speaking_s, spoken)}%
            </dd>
            <dt>Palavras por minuto</dt>
            <dd>
              Você {Math.round(m.you.wpm)} · Outros {Math.round(m.others.wpm)}
            </dd>
            <dt>Perguntas</dt>
            <dd>
              Você {m.you.questions} · Outros {m.others.questions}
            </dd>
            <dt>Silêncio</dt>
            <dd>{clock(m.silence_s)}</dd>
          </dl>
        ) : (
          <p className={styles.hint}>Ainda sem fala</p>
        )}
        <label className={styles.toggle}>
          <input type="checkbox" checked={copilot.nudges} onChange={(e) => onToggle({ nudges: e.target.checked })} />
          Avisos de conversa
        </label>
      </section>
      <section className={styles.sideSection}>
        <h4 className={styles.sideTitle}>Copiloto</h4>
        <label className={styles.toggle}>
          <input type="checkbox" checked={copilot.assist} onChange={(e) => onToggle({ assist: e.target.checked })} />
          Sugestões ao vivo
        </label>
        {copilot.assist && (
          <p className={styles.hint}>O trecho recente da conversa vai para o motor de IA ativo.</p>
        )}
        <ul className={styles.items}>
          {copilot.items.map((item) => (
            <li key={item.id}>
              <strong>{item.label}:</strong> {item.text}
            </li>
          ))}
        </ul>
      </section>
      {brainSearch && (
        <section className={styles.sideSection}>
          <h4 className={styles.sideTitle}>Brain</h4>
          <label className={styles.toggle}>
            <input type="checkbox" checked={copilot.lookup} onChange={(e) => onToggle({ lookup: e.target.checked })} />
            Buscar nomes citados
          </label>
          {copilot.lookup && (
            <>
              <label className={styles.toggle}>
                <input
                  type="checkbox"
                  checked={copilot.lookup_others}
                  onChange={(e) => onToggle({ lookup_others: e.target.checked })}
                />
                Incluir o que os Outros falam
              </label>
              <p className={styles.hint}>Os títulos das notas aparecem na tela: cuidado ao compartilhar.</p>
            </>
          )}
          <ul className={styles.items}>
            {copilot.hits.map((hit) => (
              <li key={hit.path} title={hit.snippet}>
                {hit.title}
              </li>
            ))}
          </ul>
        </section>
      )}
      {copilot.checklist.length > 0 && (
        <section className={styles.sideSection}>
          <h4 className={styles.sideTitle}>Checklist</h4>
          {copilot.checklist.map((item) => (
            <label key={item.id} className={styles.toggle}>
              <input type="checkbox" checked={item.done} onChange={(e) => onCheck(item.id, e.target.checked)} />
              {item.text}
            </label>
          ))}
        </section>
      )}
    </aside>
  );
}
