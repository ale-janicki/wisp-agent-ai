import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError } from "../../api/client";
import { TasksIcon } from "../../shell/icons";
import { useFeatureApi, useShell } from "../../shell/context";
import { TabCard, TabMessage } from "../../shell/TabCard";
import { filterGroups, itemKey, urgentFirst, type TaskGroup, type TaskItem } from "./filter";
import styles from "./TasksTab.module.css";

export const REFRESH_MS = 30_000;
export const BRAIN_OPEN_KEY = "wisp.brain.open";

type Listing = { configured: boolean; file?: string; brain_path?: string | null; groups: TaskGroup[]; open_count: number };
type State = { kind: "loading" } | { kind: "failed"; message: string } | { kind: "loaded"; listing: Listing };

function ConfirmDelete({ onConfirm, busy }: { onConfirm: () => void; busy: boolean }) {
  const [asking, setAsking] = useState(false);
  if (asking)
    return (
      <span className={styles.ask}>
        <span>Apagar?</span>
        <button type="button" aria-label="Confirmar" disabled={busy} onClick={onConfirm}>
          Sim
        </button>
        <button type="button" aria-label="Cancelar" onClick={() => setAsking(false)}>
          Não
        </button>
      </span>
    );
  return (
    <button type="button" className={styles.trash} aria-label="Apagar tarefa" title="Apagar tarefa" onClick={() => setAsking(true)}>
      🗑
    </button>
  );
}

function TaskRow({ item, busy, onDone, onOpen }: { item: TaskItem; busy: boolean; onDone: () => void; onOpen: () => void }) {
  const caption = [item.front, item.detail || null].filter(Boolean).join(" · ");
  return (
    <li className={styles.row} title={[item.title, item.detail].filter(Boolean).join("\n")}>
      <button type="button" className={styles.body} onClick={onOpen}>
        {item.urgent && <span className={styles.urgent} aria-label="Urgente" />}
        <span className={styles.text}>
          <span className={styles.line}>
            {item.owner && <span className={styles.owner}>{item.owner}</span>}
            <span className={styles.title}>{item.title}</span>
          </span>
          {caption && <span className={styles.caption}>{caption}</span>}
        </span>
      </button>
      {busy ? (
        <span className={styles.spin} aria-label="Marcando" />
      ) : (
        <>
          <ConfirmDelete busy={busy} onConfirm={onDone} />
          <button type="button" className={styles.check} aria-label="Marcar como feita" title="Marcar como feita" onClick={onDone}>
            ○
          </button>
        </>
      )}
    </li>
  );
}

const failure = (e: unknown) =>
  e instanceof ApiError && e.status === 409
    ? "essa linha mudou no arquivo; recarreguei a lista"
    : e instanceof ApiError && e.status === 423
      ? "o arquivo está ocupado por outro escritor; nada foi apagado"
      : e instanceof Error
        ? e.message
        : String(e);

export function TasksTab() {
  const raw = useFeatureApi("tasks");
  const { navigate } = useShell();
  const [state, setState] = useState<State>({ kind: "loading" });
  const [query, setQuery] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [outside, setOutside] = useState<string | null>(null);
  const generation = useRef(0);

  const load = useCallback(async () => {
    const mine = ++generation.current;
    try {
      const listing = await raw.get<Listing>("/list");
      if (mine === generation.current) setState({ kind: "loaded", listing });
    } catch (e) {
      if (mine === generation.current) setState({ kind: "failed", message: e instanceof ApiError && e.status === 500 ? "Não consegui ler o arquivo de tarefas" : "Não consegui ler as tarefas" });
    }
  }, [raw]);

  useEffect(() => {
    void load();
    const timer = setInterval(() => void load(), REFRESH_MS);
    return () => clearInterval(timer);
  }, [load]);

  const complete = async (item: TaskItem) => {
    if (busy) return;
    setBusy(itemKey(item));
    setActionError(null);
    try {
      await raw.post("/complete", { line: item.line, occurrence: item.occurrence });
    } catch (e) {
      setActionError(`Não consegui marcar como feito: ${failure(e)}`);
    }
    setBusy(null);
    await load();
  };

  const open = (item: TaskItem, listing: Listing) => {
    setOutside(null);
    if (listing.brain_path) {
      localStorage.setItem(BRAIN_OPEN_KEY, JSON.stringify({ path: listing.brain_path, line: item.index }));
      navigate("brain");
    } else if (listing.file) setOutside(`O arquivo ${listing.file} está fora do brain; abra-o pelo Explorador de Arquivos.`);
  };

  const count = state.kind === "loaded" && state.listing.configured ? `${state.listing.open_count} em aberto` : undefined;

  const content = () => {
    if (state.kind === "loading") return <TabMessage text="Carregando…" />;
    if (state.kind === "failed") return <TabMessage text={state.message} />;
    const { listing } = state;
    if (!listing.configured) return <TabMessage text={"Nenhum arquivo de tarefas configurado.\nDefina blocks.tasks.file no perfil do Wisp."} />;
    if (listing.groups.length === 0) return <TabMessage text="Nada em aberto" />;
    const shown = urgentFirst(filterGroups(listing.groups, query));
    if (shown.length === 0) return <TabMessage text={`Nenhuma tarefa com “${query}”`} />;
    return (
      <div className={styles.list}>
        {shown.map((group) => (
          <section key={group.title ?? ""} aria-label={group.title ?? "Sem seção"}>
            {group.title && <h3 className={styles.section}>{group.title}</h3>}
            <ul className={styles.items}>
              {group.items.map((item) => (
                <TaskRow key={itemKey(item)} item={item} busy={busy === itemKey(item)} onDone={() => void complete(item)} onOpen={() => open(item, listing)} />
              ))}
            </ul>
          </section>
        ))}
      </div>
    );
  };

  return (
    <TabCard title="Tarefas" icon={TasksIcon} trailing={count}>
      <div className={styles.wrap}>
        <input
          type="search"
          className={styles.search}
          aria-label="Buscar tarefas"
          placeholder="Buscar tarefas"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        {actionError && <p className={styles.error}>{actionError}</p>}
        {outside && <p className={styles.error}>{outside}</p>}
        {content()}
      </div>
    </TabCard>
  );
}
