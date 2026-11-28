import { useEffect, useState } from "react";
import { useShell } from "../../shell/context";
import { Button, ConfirmAction, Detail, Divider, Dot, Empty, Expander, Group, InlineError, Row } from "./ui";
import { useAction, useLoad, useSettingsApi } from "./hooks";
import type { CliTool, HookGroup, McpServer, RoutineRow, SettingsState } from "./types";
import styles from "./Settings.module.css";

export const ROUTINES_REFRESH_MS = 10_000;
type Kind = "integrations" | "routines" | "hooks" | "commands" | "mcp" | "clis";
const TITLES: Record<Kind, string> = { integrations: "Integrações", routines: "Rotinas", hooks: "Hooks", commands: "Comandos", mcp: "MCP", clis: "CLIs" };

type RoutinesData = { available: boolean; rows: RoutineRow[]; running: number; error?: string };
type HooksData = { available: boolean; groups: HookGroup[]; count: number; locked: number; error?: string; can_disable?: boolean; can_enable?: boolean };
type CommandsData = { available: boolean; entries: { name: string; detail: string | null; path: string }[] };
type McpData = { engine: string; servers: McpServer[] };
type ClisData = { installed: CliTool[]; missing: string[] };

export function AutomationsPane({ state }: { state: SettingsState }) {
  const api = useSettingsApi();
  const [open, setOpen] = useState<Kind | null>(null);
  const routines = useLoad(() => api.get<RoutinesData>("/routines"), state.blocks.routines ? ROUTINES_REFRESH_MS : undefined);
  const hooks = useLoad(() => api.get<HooksData>("/hooks"));
  const commands = useLoad(() => api.get<CommandsData>("/commands"));
  const mcp = useLoad(() => api.get<McpData>("/mcp"));
  const clis = useLoad(() => api.get<ClisData>("/clis"));

  const kinds = (Object.keys(TITLES) as Kind[]).filter((kind) => (kind === "routines" ? state.blocks.routines : kind === "hooks" ? state.blocks.hooks : kind === "commands" ? state.blocks.commands : true));
  const summary = (kind: Kind): string | null => {
    switch (kind) {
      case "integrations": return "2";
      case "routines": return routines.data?.rows.length ? `${routines.data.running} rodando · ${routines.data.rows.length}` : null;
      case "hooks": return hooks.data && hooks.data.available && !hooks.data.error ? (hooks.data.locked ? `${hooks.data.count} · ${hooks.data.locked} ${hooks.data.locked === 1 ? "trava" : "travas"}` : `${hooks.data.count}`) : null;
      case "commands": return commands.data ? `${commands.data.entries.length}` : null;
      case "mcp": return mcp.data ? `${mcp.data.servers.length}` : null;
      case "clis": return clis.data ? `${clis.data.installed.length}` : null;
    }
  };
  const content = (kind: Kind) => {
    switch (kind) {
      case "integrations": return <Integrations />;
      case "routines": return <Routines data={routines.data} failed={routines.failed} reload={routines.reload} />;
      case "hooks": return <Hooks data={hooks.data} failed={hooks.failed} reload={hooks.reload} />;
      case "commands": return <Commands data={commands.data} />;
      case "mcp": return <Mcp data={mcp.data} />;
      case "clis": return <Clis data={clis.data} reload={clis.reload} />;
    }
  };
  return (
    <Group title="Automações">
      {kinds.map((kind, index) => (
        <div key={kind}>
          {index > 0 && <Divider />}
          <Expander title={TITLES[kind]} summary={summary(kind)} open={open === kind} onToggle={() => setOpen(open === kind ? null : kind)}>
            {content(kind)}
          </Expander>
        </div>
      ))}
    </Group>
  );
}

function Integrations() {
  const { navigate } = useShell();
  return (
    <>
      <Row title="Spotify" detail="Conecte pela aba Música.">
        <Button onClick={() => navigate("music")}>Abrir Música</Button>
      </Row>
      <Divider />
      <Row title="Google Agenda" detail="Conecte pela aba Agenda.">
        <Button onClick={() => navigate("agenda")}>Abrir Agenda</Button>
      </Row>
    </>
  );
}

const DOT: Record<RoutineRow["state"], "ok" | "ring" | "error" | "plain"> = { running: "ok", waiting: "plain", failed: "error", unloaded: "ring", missing: "error" };

function Routines({ data, failed, reload }: { data: RoutinesData | null; failed: boolean; reload: () => Promise<void> }) {
  const api = useSettingsApi();
  const action = useAction();
  const [logOf, setLogOf] = useState<RoutineRow | null>(null);
  if (logOf) return <RoutineLog row={logOf} close={() => setLogOf(null)} />;
  if (failed && !data) return <Empty text="Não consegui ler as rotinas." />;
  if (!data) return <Empty text="Lendo as rotinas…" />;
  if (data.error) return <Empty text={data.error} />;
  if (!data.rows.length) return <Empty text="Nenhuma rotina encontrada" />;
  const toggle = async (row: RoutineRow) => {
    const on = row.state === "unloaded";
    const answer = await action.run(row.label, () => api.post<{ ok: boolean; error?: string }>("/routines/toggle", { label: row.label, on }), `Não consegui ${on ? "ligar" : "desligar"} ${row.name}.`);
    if (answer && !answer.ok) action.fail(row.label, answer.error ?? "Não consegui alterar a rotina.");
    await reload();
  };
  return (
    <>
      {data.rows.map((row, index) => (
        <div key={row.label}>
          {index > 0 && <Divider />}
          <div className={styles.row}>
            <Dot tone={DOT[row.state]} />
            <div className={styles.label} title={row.label}>
              <span className={row.state === "unloaded" ? styles.dim : styles.title}>{row.name}</span>
              {row.description && <span className={styles.detail}>{row.description}</span>}
              <span className={`${styles.detail} ${styles.mono}`}>{row.summary}</span>
            </div>
            <div className={styles.controls}>
              {row.logs.length > 0 && <Button onClick={() => setLogOf(row)}>Log</Button>}
              {row.installed && (
                <ConfirmAction
                  label={row.state === "unloaded" ? "Ligar" : "Desligar"}
                  question={`${row.state === "unloaded" ? "Ligar" : "Desligar"} ${row.name}?`}
                  busy={action.busy === row.label}
                  onConfirm={() => void toggle(row)}
                />
              )}
            </div>
          </div>
          {action.error?.key === row.label && <InlineError text={action.error.text} />}
        </div>
      ))}
    </>
  );
}

type LogData = { ok: boolean; lines?: string[]; error?: string; path?: string; paths?: string[] };

function RoutineLog({ row, close }: { row: RoutineRow; close: () => void }) {
  const api = useSettingsApi();
  const [index, setIndex] = useState(0);
  const [log, setLog] = useState<LogData | null>(null);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let live = true;
    setLog(null);
    api.get<LogData>("/routines/log", { label: row.label, index }).then((l) => live && setLog(l)).catch(() => live && setLog({ ok: false, error: "Não consegui ler o log." }));
    return () => {
      live = false;
    };
  }, [api, row.label, index, tick]);
  const name = (path: string) => path.split(/[\\/]/).pop() ?? path;
  return (
    <div>
      <div className={styles.controls}>
        <Button aria-label="Voltar às rotinas" onClick={close}>‹</Button>
        {row.logs.length > 1 && row.logs.map((path, i) => <Button key={path} kind={i === index ? "accent" : undefined} onClick={() => setIndex(i)}>{name(path)}</Button>)}
        <Detail text={log?.path ?? row.logs[index] ?? ""} />
        <Button aria-label="Ler de novo" onClick={() => setTick(tick + 1)}>↻</Button>
      </div>
      {!log && <Empty text="Lendo o log…" />}
      {log && !log.ok && <Empty text={log.error ?? "Não consegui ler o log."} />}
      {log?.ok && (log.lines?.length ? <pre className={styles.log}>{log.lines.join("\n")}</pre> : <Empty text="Log vazio" />)}
    </div>
  );
}

function Hooks({ data, failed, reload }: { data: HooksData | null; failed: boolean; reload: () => Promise<void> }) {
  const api = useSettingsApi();
  const action = useAction();
  if (failed && !data) return <Empty text="Não consegui listar os hooks." />;
  if (!data) return <Empty text="Lendo os hooks…" />;
  if (data.error) return <Empty text={data.error} />;
  if (!data.count) return <Empty text="Nenhum hook configurado" />;
  const toggle = async (hook: HookGroup["hooks"][number]) => {
    const answer = await action.run(hook.id, () => api.post<{ ok: boolean; error?: string }>("/hooks/toggle", { id: hook.id, on: !hook.enabled }), `Não consegui ${hook.enabled ? "desligar" : "ligar"} ${hook.title}.`);
    if (answer && !answer.ok) action.fail(hook.id, answer.error ?? "Não consegui alterar o hook.");
    await reload();
  };
  return (
    <>
      {data.groups.map((group) => (
        <div key={group.event}>
          <Detail text={group.title} />
          {group.hooks.map((hook, index) => {
            const can = !hook.locked && (hook.enabled ? data.can_disable : data.can_enable);
            return (
              <div key={hook.id}>
                {index > 0 && <Divider />}
                <div className={styles.row}>
                  <div className={styles.label} title={hook.command}>
                    <span className={hook.enabled ? styles.title : styles.dim}>{hook.title}</span>
                    {hook.detail && <span className={styles.detail}>{hook.detail}</span>}
                    {hook.missing && <span className={`${styles.busy} ${styles.mono}`}>script ausente</span>}
                  </div>
                  <div className={styles.controls}>
                    {hook.locked ? (
                      <span className={styles.detail}>🔒 trava</span>
                    ) : (
                      can && <ConfirmAction label={hook.enabled ? "Desligar" : "Ligar"} question={`${hook.enabled ? "Desligar" : "Ligar"} ${hook.title}?`} busy={action.busy === hook.id} onConfirm={() => void toggle(hook)} />
                    )}
                  </div>
                </div>
                {action.error?.key === hook.id && <InlineError text={action.error.text} />}
              </div>
            );
          })}
        </div>
      ))}
    </>
  );
}

function Commands({ data }: { data: CommandsData | null }) {
  if (!data) return <Empty text="Lendo os comandos…" />;
  if (!data.entries.length) return <Empty text="Nenhum comando encontrado" />;
  return (
    <>
      {data.entries.map((entry, index) => (
        <div key={entry.path} title={entry.path}>
          {index > 0 && <Divider />}
          <Row title={entry.name} detail={entry.detail} />
        </div>
      ))}
    </>
  );
}

const ENGINE_NAMES: Record<string, string> = { claude: "Claude", codex: "Codex", local: "IA local" };

function Mcp({ data }: { data: McpData | null }) {
  return (
    <>
      <Detail text={`Servidores que o motor ${ENGINE_NAMES[data?.engine ?? "claude"] ?? "Claude"} enxerga, lidos da configuração (nenhum é iniciado aqui). Env, cabeçalhos e argumentos nunca aparecem.`} />
      {!data && <Empty text="Lendo a configuração…" />}
      {data && !data.servers.length && <Empty text="Nenhum servidor MCP configurado para este motor." />}
      {data?.servers.map((server, index) => (
        <div key={`${server.scope}/${server.name}`}>
          {index > 0 && <Divider />}
          <Row title={server.name} detail={[server.transport, server.scope, server.installed_by_wisp ? "instalado pelo Wisp" : null].filter(Boolean).join(" · ")}>
            <Dot tone={server.disabled ? "ring" : "ok"} />
            <span className={styles.dim}>{server.disabled ? "desativado" : "configurado"}</span>
          </Row>
        </div>
      ))}
    </>
  );
}

function Clis({ data, reload }: { data: ClisData | null; reload: () => Promise<void> }) {
  const api = useSettingsApi();
  const [scanning, setScanning] = useState(false);
  const [showMissing, setShowMissing] = useState(false);
  const refresh = async () => {
    setScanning(true);
    try {
      await api.get("/clis", { force: 1 });
    } finally {
      setScanning(false);
    }
    await reload();
  };
  return (
    <>
      <div className={styles.controls}>
        <Detail text="A IA usa estas ferramentas pelo terminal dela; as travas do Wisp ainda valem." />
        <Button disabled={scanning} onClick={() => void refresh()}>{scanning ? "…" : "Atualizar"}</Button>
      </div>
      {!data && <Empty text="Procurando as ferramentas…" />}
      {data?.installed.map((tool, index) => (
        <div key={tool.name}>
          {index > 0 && <Divider />}
          <Row title={tool.name} detail={[tool.version, tool.directory].filter(Boolean).join(" · ")}>
            {tool.auth && (
              <>
                <Dot tone="ok" />
                <span className={styles.dim}>{tool.auth}</span>
              </>
            )}
          </Row>
        </div>
      ))}
      {data && data.missing.length > 0 && (
        <Expander title={`Não encontradas (${data.missing.length})`} open={showMissing} onToggle={() => setShowMissing(!showMissing)}>
          <Detail text={data.missing.join(", ")} />
        </Expander>
      )}
    </>
  );
}
