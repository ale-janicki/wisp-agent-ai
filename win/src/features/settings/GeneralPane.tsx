import { useEffect, useState } from "react";
import { Button, Detail, Divider, Group, InlineError, Row, TextInput, ToggleRow, sentence } from "./ui";
import { useAction, useLoad, useSettingsApi } from "./hooks";
import { loginSentence, tauriLoginItem, type LoginItemApi } from "./loginItem";
import type { Lesson, LoginStatus, Report, SettingsState } from "./types";

const FOLDER_CONTENTS: [string, string][] = [
  ["conversas/", "o histórico de cada conversa"],
  ["reunioes/", "gravações, transcrições e notas das reuniões"],
  ["brain/", "suas notas e o que o Wisp aprendeu (pode ficar em outra pasta)"],
  ["modelos/", "os modelos locais baixados pelo Wisp"],
  ["anexos/", "arquivos enviados pelo app e pelo Telegram"],
  ["skills/", "habilidades do agente"],
  ["ferramentas/", "ferramentas extras do agente"],
  ["logs/", "registros do bot e das mudanças de pasta"],
  ["agente.md", "as instruções do agente"],
  ["guardrails.toml", "o que o agente pode fazer"],
  ["modelos.toml", "o motor e os modelos"],
];

type Props = { state: SettingsState; reload: () => Promise<void>; openSetup: () => void; loginItem?: LoginItemApi };

export function GeneralPane({ state, reload, openSetup, loginItem = tauriLoginItem }: Props) {
  return (
    <>
      <Group title="Geral">
        <LoginItemRow api={loginItem} />
        <Divider />
        <PathRow title="Pasta do Wisp" keyName="wisp_dir" value={state.paths.wisp_dir} isDefault={!state.paths.has_wisp_dir && state.paths.wisp_dir === "~/Wisp"} reload={reload} />
        <details>
          <summary>O que tem dentro</summary>
          {FOLDER_CONTENTS.map(([name, detail]) => (
            <Detail key={name} text={`${name}  ${detail}`} mono />
          ))}
        </details>
        <Divider />
        <Row title="Setup" detail="Abre de novo a tela que reconhece o PC e confere o motor, o cérebro e as ferramentas. Começar só refaz o que faltar ou o que você mudar.">
          <Button onClick={openSetup}>Rodar o setup de novo</Button>
        </Row>
      </Group>
      <BrainGroup state={state} reload={reload} />
    </>
  );
}

function LoginItemRow({ api }: { api: LoginItemApi }) {
  const [status, setStatus] = useState<LoginStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (api.available) void api.status().then(setStatus).catch(() => {});
  }, [api]);
  const set = async (on: boolean) => {
    setError(null);
    try {
      setStatus(await api.set(on));
    } catch (e) {
      setError(`Não consegui ajustar a abertura ao ligar o Windows: ${String(e)}`);
    }
  };
  const on = status?.state === "enabled";
  return (
    <ToggleRow
      title="Abrir ao ligar o Windows"
      detail={api.available ? loginSentence(status, error) : "Disponível quando o Wisp estiver instalado."}
      detailTone={error ? "error" : undefined}
      on={on}
      enabled={api.available}
      onChange={(next) => void set(next)}
    />
  );
}

function PathRow({ title, keyName, value, isDefault, reload }: { title: string; keyName: "wisp_dir" | "brain"; value: string; isDefault: boolean; reload: () => Promise<void> }) {
  const api = useSettingsApi();
  const action = useAction();
  const [draft, setDraft] = useState(value);
  const [editing, setEditing] = useState(false);
  useEffect(() => setDraft(value), [value]);
  const apply = async () => {
    const report = await action.run(keyName, () => api.post<Report>("/path", { key: keyName, value: draft.trim() }), "Não consegui rodar o wisp.");
    if (report?.status === "failed") action.fail(keyName, sentence(report.summary));
    if (report && report.status !== "failed") setEditing(false);
    await reload();
  };
  return (
    <div>
      <Row title={title} detail={isDefault ? `${value} (padrão)` : value}>
        {editing ? (
          <>
            <TextInput aria-label={`Caminho: ${title}`} value={draft} onChange={(e) => setDraft(e.target.value)} />
            <Button kind="accent" disabled={!!action.busy || !draft.trim()} onClick={() => void apply()}>Aplicar</Button>
            <Button onClick={() => { setEditing(false); setDraft(value); }}>Cancelar</Button>
          </>
        ) : (
          <Button disabled={!!action.busy} onClick={() => setEditing(true)}>Trocar…</Button>
        )}
      </Row>
      {editing && <Detail text="Trocar o caminho não move nada: aponta o Wisp para outra pasta. Use um caminho completo (como C:\Users\você\Wisp)." />}
      {action.error && <InlineError text={action.error.text} />}
    </div>
  );
}

function BrainGroup({ state, reload }: { state: SettingsState; reload: () => Promise<void> }) {
  const api = useSettingsApi();
  const action = useAction();
  const lessons = useLoad(() => api.get<{ lessons: Lesson[]; pending: Lesson[] }>("/lessons"));
  const brain = state.paths.brain;
  const create = async () => {
    const answer = await action.run("create", () => api.post<{ ok: boolean; error?: string }>("/brain/create"), "Não consegui rodar o comando do Wisp.");
    if (answer && !answer.ok) action.fail("create", answer.error ?? "Não consegui criar o cérebro.");
    await reload();
    await lessons.reload();
  };
  const learn = async (on: boolean) => {
    const answer = await action.run("learn", () => api.post<{ ok: boolean; error?: string }>("/learn", { on }), "Não consegui salvar no wisp.json.");
    if (answer && !answer.ok) action.fail("learn", answer.error ?? "Não consegui salvar no wisp.json.");
    await reload();
  };
  const change = async (kind: "confirm" | "discard" | "forget", lesson: Lesson) => {
    const answer = await action.run(`lesson-${kind}-${lesson.number}`, () => api.post<{ ok: boolean; error?: string }>(`/lessons/${kind}`, { number: lesson.number }), "Não consegui salvar no wisp.json.");
    if (answer && !answer.ok) action.fail("lesson", answer.error ?? "Essa regra não existe mais.");
    await lessons.reload();
  };
  const data = lessons.data;
  return (
    <Group title="Brain">
      <PathRow title="Pasta do brain" keyName="brain" value={brain ?? "Nenhuma pasta escolhida"} isDefault={false} reload={reload} />
      {state.paths.brain_missing && (
        <>
          <Divider />
          <Row title="Criar o cérebro" detail="Confere se a pasta já existe e, se não existir, cria com o modelo do Wisp e atualiza o perfil.">
            <Button kind="accent" disabled={action.busy === "create"} onClick={() => void create()}>Criar o cérebro</Button>
          </Row>
        </>
      )}
      <Divider />
      <ToggleRow title="Aprender com as conversas" detail="Depois de 30 min sem mensagens, o Wisp guarda no brain o que a conversa teve de importante. Usa o seu plano." on={state.paths.brain_learn} onChange={(on) => void learn(on)} />
      <Divider />
      <Row
        title="O que o Wisp aprendeu"
        detail={data?.lessons.length ? "Preferências que o Wisp segue em toda conversa. Remover faz ele esquecer." : "Quando você corrigir o Wisp ou disser como prefere as coisas, ele guarda aqui e passa a seguir em toda conversa."}
      />
      {data?.pending.map((lesson) => (
        <div key={`p${lesson.number}`}>
          <Divider />
          <Row title={lesson.rule} detail={`Quer aprender, esperando você confirmar${lesson.date ? ` · ${lesson.date}` : ""}`}>
            <Button onClick={() => void change("confirm", lesson)}>Confirmar</Button>
            <Button onClick={() => void change("discard", lesson)}>Descartar</Button>
          </Row>
        </div>
      ))}
      {data?.lessons.map((lesson) => (
        <div key={`l${lesson.number}`}>
          <Divider />
          <Row title={lesson.rule} detail={[lesson.learned_alone ? "aprendido sozinho" : lesson.origin, lesson.date].filter(Boolean).join(" · ")}>
            <Button onClick={() => void change("forget", lesson)}>Remover</Button>
          </Row>
        </div>
      ))}
      {action.error && <InlineError text={action.error.text} />}
    </Group>
  );
}

type TelegramState = { configured: boolean };
type TelegramAnswer = { ok: boolean; message: string; token_stored: boolean; configured: boolean };

export function TelegramGroup({ optional = false }: { optional?: boolean }) {
  const api = useSettingsApi();
  const status = useLoad(() => api.get<TelegramState>("/telegram"));
  const [token, setToken] = useState("");
  const [stored, setStored] = useState(false);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ text: string; failed: boolean } | null>(null);
  const run = async (action: "connect" | "discover" | "disconnect") => {
    if (busy) return;
    setBusy(true);
    setMessage(null);
    try {
      const answer = await api.post<TelegramAnswer>("/telegram", { action, ...(action === "connect" ? { token } : {}) });
      setMessage({ text: answer.message, failed: !answer.ok });
      if (action === "connect") {
        setStored(answer.token_stored);
        if (answer.ok) setToken("");
      }
      if (action === "disconnect") setStored(false);
    } catch {
      setMessage({ text: "Não consegui falar com o Telegram. Tente de novo.", failed: true });
    } finally {
      setBusy(false);
      await status.reload();
    }
  };
  const configured = status.data?.configured === true;
  return (
    <Group title={optional ? "Telegram (opcional)" : "Telegram"} caption="Converse com o Wisp pelo celular. Crie um bot no BotFather, cole o token aqui e mande 'oi' no grupo.">
      {configured ? (
        <Row title="Telegram conectado" detail="O bot do Wisp está configurado neste PC.">
          <Button disabled={busy} onClick={() => void run("discover")}>Conferir o bot</Button>
          <Button disabled={busy} onClick={() => void run("disconnect")}>Desconectar</Button>
        </Row>
      ) : stored ? (
        <Row title="Token guardado" detail="Mande 'oi' no grupo do bot e toque em Procurar o grupo.">
          <Button kind="accent" disabled={busy} onClick={() => void run("discover")}>Procurar o grupo</Button>
        </Row>
      ) : (
        <Row title="Conectar Telegram" detail="Token do bot (criado no BotFather)">
          <TextInput type="password" aria-label="Token do bot" placeholder="cole o token aqui" value={token} onChange={(e) => setToken(e.target.value)} />
          <Button kind="accent" disabled={busy || !token.trim()} onClick={() => void run("connect")}>Conectar Telegram</Button>
        </Row>
      )}
      {message && (message.failed ? <InlineError text={message.text} /> : <Detail text={message.text} />)}
    </Group>
  );
}
