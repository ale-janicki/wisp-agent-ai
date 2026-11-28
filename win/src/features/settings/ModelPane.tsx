import { useEffect, useRef, useState } from "react";
import type { FeatureApi } from "../../api/feature";
import { Button, Detail, Group, InlineError, Radio, sentence } from "./ui";
import { useAction, useLoad, useSettingsApi } from "./hooks";
import type { DoctorReport, EngineId, PermissionChoice, Report, SettingsState } from "./types";

export const LOGIN_POLL_MS = 3000;
export const LOGIN_TIMEOUT_MS = 10 * 60 * 1000;
const NAMES: Record<EngineId, string> = { claude: "Claude", codex: "Codex", local: "IA local" };
const ENGINES: EngineId[] = ["claude", "codex", "local"];
const CLAUDE_INSTALL = "irm https://claude.ai/install.ps1 | iex";

type Props = { state: SettingsState; reload: () => Promise<void> };

const OPTIONS: Record<EngineId, [PermissionChoice, string, string][]> = {
  claude: [
    ["default", "Pedir minha aprovação", "O Claude pergunta aqui no Wisp antes de rodar um comando ou mexer num arquivo."],
    ["auto", "Automático", "O Claude decide sozinho o que é seguro; pode executar ações destrutivas sem perguntar."],
    ["bypassPermissions", "Sem pedir (perigoso)", "O Claude roda qualquer comando e edita qualquer arquivo sem perguntar."],
  ],
  codex: [
    ["default", "Pedir minha aprovação", "O Codex não consegue pedir aprovação aqui, então só lê: não escreve arquivos nem altera nada."],
    ["auto", "Automático", "Igual a Sem pedir: o Codex só escreve na pasta de trabalho, sem rede e sem sair do isolamento. Ele não decide sozinho o que é seguro."],
    ["bypassPermissions", "Sem pedir (perigoso)", "O Codex roda sem perguntar, mas só escreve na pasta de trabalho (nunca na pasta pessoal inteira) e sem rede."],
  ],
  local: [
    ["default", "Pedir minha aprovação", "A IA local pergunta aqui no Wisp antes de gravar um arquivo ou usar uma ferramenta que mude algo."],
    ["auto", "Automático", "A IA local só pergunta o que é irreversível (enviar e-mail, rodar comando) e o que o nível do modelo exige."],
    ["bypassPermissions", "Sem pedir (perigoso)", "Igual ao Automático: enviar e-mail e rodar comando continuam pedindo, sempre."],
  ],
};

const BYPASS_WARNING: Record<EngineId, string> = {
  local: "Sem pedir, a IA local grava arquivos sem perguntar. Enviar e-mail e rodar comando continuam pedindo sempre.",
  codex: "Sem pedir, o Codex age sem perguntar dentro da pasta de trabalho. As travas do Wisp (hooks) não existem no Codex: o que protege é o sandbox do sistema.",
  claude: "Sem pedir, o Claude age sem perguntar nada. Só as regras de bloqueio do Claude e os hooks continuam valendo.",
};

function permissionNote(state: SettingsState): string | null {
  const { source, claude_mode, choice } = state.permission;
  if (source === "claude") return `Definido no Claude${choice === null ? ` (${claude_mode}, sem equivalente aqui)` : ""}, em ~/.claude/settings.json. Escolher aqui vale para o Wisp e não muda esse arquivo.`;
  if (source === "wisp") return "Teu perfil é gerenciado fora do Wisp, então esta escolha fica nos ajustes do Wisp; o bot do Telegram neste PC lê de lá.";
  return null;
}

export function ModelPane({ state, reload }: Props) {
  const api = useSettingsApi();
  const doctor = useLoad(() => api.get<DoctorReport>("/doctor", { only: "claude,claude_login,codex,codex_login" }));
  const engine = useAction();
  const [notice, setNotice] = useState<string | null>(null);
  const check = (id: string) => doctor.data?.checks.find((c) => c.id === id);

  const select = async (kind: EngineId) => {
    if (kind === state.engine || engine.busy) return;
    setNotice(null);
    const report = await engine.run("engine", () => api.post<Report>("/engine", { engine: kind }), "Não consegui rodar o wisp.");
    if (!report) return;
    if (report.status === "failed") engine.fail("engine", sentence(report.summary));
    else setNotice(report.data.harness === "managed_elsewhere" ? report.summary : null);
    await reload();
    await doctor.reload();
  };

  const status = (kind: EngineId): string => {
    if (kind === "claude") return "É o motor padrão do Wisp.";
    if (kind === "local") return "A IA local ainda não roda no Windows. Use o Claude ou o Codex.";
    if (!doctor.data) return "Conferindo o Codex…";
    const fallback = state.engine === "codex" ? " Enquanto isso o Wisp responde pelo Claude." : "";
    if (check("codex")?.ok && check("codex_login")?.ok) return "Codex instalado e com login feito.";
    if (check("codex")?.ok) return "Codex instalado, mas falta entrar: use Conectar Codex.";
    return `Codex não está instalado neste PC.${fallback}`;
  };

  return (
    <>
      <Group title="Motor" caption="Quem responde no app e no Telegram, a partir da próxima mensagem. Ao trocar, o novo motor retoma pela conversa guardada no Wisp.">
        {ENGINES.map((kind) => (
          <div key={kind}>
            <Radio selected={state.engine === kind} title={NAMES[kind]} detail={status(kind)} disabled={!!engine.busy || kind === "local"} onSelect={() => void select(kind)} />
            {kind === state.engine && kind !== "local" && <ConnectBlock api={api} kind={kind} doctor={doctor.data} recheck={doctor.reload} />}
          </div>
        ))}
        {state.engine === "codex" && (
          <Detail text="No Codex o Wisp não recebe pedidos de aprovação: o que protege é o sandbox do sistema, e as travas do Wisp (hooks) só existem no Claude. Enviar e-mail continua pedindo a tua aprovação." />
        )}
        {notice && <Detail text={notice} />}
        {engine.error && <InlineError text={engine.error.text} />}
      </Group>
      <PermissionGroup state={state} reload={reload} />
    </>
  );
}

type Flow = "idle" | "waiting" | "connected" | "timed_out";

function ConnectBlock({ api, kind, doctor, recheck }: { api: FeatureApi; kind: "claude" | "codex"; doctor: DoctorReport | null; recheck: () => Promise<void> }) {
  const [flow, setFlow] = useState<Flow>("idle");
  const [error, setError] = useState<string | null>(null);
  const started = useRef(0);
  const checks = Object.fromEntries((doctor?.checks ?? []).map((c) => [c.id, c]));
  const installed = checks[kind]?.ok === true;
  const loggedIn = checks[`${kind}_login`]?.ok === true;

  useEffect(() => {
    if (flow !== "waiting") return;
    const timer = setInterval(() => {
      void api
        .get<DoctorReport>("/doctor", { only: `${kind},${kind}_login` })
        .then((report) => {
          if (report.checks.find((c) => c.id === `${kind}_login`)?.ok) {
            setFlow("connected");
            void recheck();
          } else if (Date.now() - started.current >= LOGIN_TIMEOUT_MS) setFlow("timed_out");
        })
        .catch(() => {});
    }, LOGIN_POLL_MS);
    return () => clearInterval(timer);
  }, [flow, api, kind, recheck]);

  if (!doctor) return null;
  const name = NAMES[kind];
  if (loggedIn || flow === "connected") return <Detail text="Conectado" />;
  if (!installed) {
    return (
      <div>
        <Detail text={`${name} não está instalado neste PC.`} />
        {kind === "claude" ? (
          <>
            <Detail text="Cole este comando no PowerShell para instalar:" />
            <Detail text={CLAUDE_INSTALL} mono />
            <Button onClick={() => void navigator.clipboard?.writeText(CLAUDE_INSTALL)}>Copiar comando</Button>
          </>
        ) : (
          <Detail text="Instale com: npm install -g @openai/codex" mono />
        )}
        <Button onClick={() => void recheck()}>Conferir de novo</Button>
      </div>
    );
  }
  const open = async () => {
    setError(null);
    try {
      const answer = await api.post<{ ok: boolean; error?: string }>("/setup/login", { engine: kind });
      if (!answer.ok) return setError(answer.error ?? "Não consegui abrir o terminal do login.");
      started.current = Date.now();
      setFlow("waiting");
    } catch {
      setError("Não consegui abrir o terminal do login.");
    }
  };
  return (
    <div>
      {flow === "waiting" ? (
        <Detail text="Esperando o login no terminal…" />
      ) : (
        <>
          {flow === "timed_out" && <Detail text="O login não apareceu em 10 minutos. Conecte de novo quando quiser." />}
          <Detail text="Uma janela de terminal abre e pede o login do Claude." />
          <Button kind="accent" onClick={() => void open()}>{`Conectar ${name}`}</Button>
        </>
      )}
      {error && <InlineError text={error} />}
    </div>
  );
}

function PermissionGroup({ state, reload }: Props) {
  const api = useSettingsApi();
  const action = useAction();
  const [confirming, setConfirming] = useState(false);
  const options = OPTIONS[state.engine];
  const select = async (choice: PermissionChoice) => {
    const answer = await action.run("permission", () => api.post<{ ok: boolean; error: string | null }>("/permission", { choice }), "Não consegui salvar no perfil.");
    if (answer && !answer.ok && answer.error) action.fail("permission", answer.error);
    await reload();
  };
  const note = permissionNote(state);
  return (
    <Group title={`Permissões do ${NAMES[state.engine]}`} caption="Vale para as conversas do Wisp a partir da próxima mensagem; uma resposta em andamento termina no modo anterior.">
      {options.map(([choice, title, detail]) => (
        <Radio
          key={choice}
          selected={state.permission.choice === choice}
          title={title}
          detail={detail}
          titleTone={choice === "bypassPermissions" ? "error" : undefined}
          onSelect={() => {
            if (state.permission.choice === choice) return;
            if (choice === "bypassPermissions") setConfirming(true);
            else {
              setConfirming(false);
              void select(choice);
            }
          }}
        />
      ))}
      <Detail text={'Nas conversas do Telegram, "Pedir minha aprovação" roda como Automático.'} />
      {confirming && (
        <div>
          <Detail text={BYPASS_WARNING[state.engine]} />
          <Button
            kind="danger"
            onClick={() => {
              setConfirming(false);
              void select("bypassPermissions");
            }}
          >
            Usar sem pedir
          </Button>
          <Button onClick={() => setConfirming(false)}>Cancelar</Button>
        </div>
      )}
      {note && <Detail text={note} />}
      {action.error && <InlineError text={action.error.text} />}
    </Group>
  );
}
