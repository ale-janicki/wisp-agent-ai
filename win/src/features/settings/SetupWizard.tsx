import { useCallback, useEffect, useRef, useState } from "react";
import { TabCard } from "../../shell/TabCard";
import { GearIcon } from "../../shell/icons";
import { Button, Detail, Divider, Group, InlineError, Row, TextInput, sentence } from "./ui";
import { useSettingsApi } from "./hooks";
import { TelegramGroup } from "./GeneralPane";
import type { Detail as StepDetail, DoctorReport, Report, SettingsState } from "./types";
import styles from "./Settings.module.css";

export const WIZARD_LOGIN_POLL_MS = 3000;
export const WIZARD_LOGIN_TIMEOUT_MS = 10 * 60 * 1000;

export type StepId = "system" | "login" | "brain" | "harness" | "profile";
type Phase = "idle" | "running" | "done" | "skipped" | "needs_user" | "failed";
type Step = { phase: Phase; summary: string; details: StepDetail[] };

const ORDER: StepId[] = ["system", "login", "brain", "harness", "profile"];
const TITLES: Record<StepId, string> = {
  system: "Git e Claude Code",
  login: "Login no Claude",
  brain: "Seu cérebro",
  harness: "As ferramentas do Claude",
  profile: "Seu perfil",
};
const RUNNING: Record<StepId, string> = {
  system: "Conferindo o PC e instalando o que falta",
  login: "Esperando o login no terminal",
  brain: "Criando o seu cérebro",
  harness: "Instalando as ferramentas",
  profile: "Montando o seu perfil",
};
const DOCTOR_CHECKS: Record<StepId, string[]> = { system: ["git", "claude"], login: ["claude_login"], brain: ["brain"], harness: ["harness"], profile: ["profile"] };
const ICON: Record<Phase, string> = { idle: "○", running: "…", done: "✓", skipped: "✓", needs_user: "!", failed: "✕" };
const TONE: Record<Phase, string | undefined> = { idle: styles.dim, running: styles.wait, done: styles.ok, skipped: styles.ok, needs_user: styles.wait, failed: styles.bad };

const idle = (): Step => ({ phase: "idle", summary: "", details: [] });
const blank = (): Record<StepId, Step> => ({ system: idle(), login: idle(), brain: idle(), harness: idle(), profile: idle() });
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

type Props = { state: SettingsState; onFinish: () => void; onClose?: () => void };

export function SetupWizard({ state, onFinish, onClose }: Props) {
  const api = useSettingsApi();
  const [steps, setSteps] = useState(blank);
  const [running, setRunning] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [name, setName] = useState(state.profile.name);
  const [user, setUser] = useState(state.profile.user);
  const [open, setOpen] = useState<StepId | null>(null);
  const [allDone, setAllDone] = useState(false);
  const live = useRef(true);
  useEffect(() => () => void (live.current = false), []);

  const patch = useCallback((id: StepId, next: Partial<Step>) => live.current && setSteps((s) => ({ ...s, [id]: { ...s[id], ...next } })), []);

  const readiness = useCallback(async (): Promise<Record<StepId, boolean>> => {
    const report = await api.get<DoctorReport>("/doctor", { only: "git,claude,claude_login,brain,harness,profile" });
    const ok = (id: string) => report.checks.find((c) => c.id === id)?.ok === true;
    const ready = Object.fromEntries(ORDER.map((id) => [id, DOCTOR_CHECKS[id].every(ok)])) as Record<StepId, boolean>;
    for (const id of ORDER) {
      if (!ready[id]) continue;
      const checks = report.checks.filter((c) => DOCTOR_CHECKS[id].includes(c.id));
      patch(id, { phase: "done", summary: checks.map((c) => sentence(c.summary)).join(" · "), details: [{ command: `wisp doctor --json --only ${DOCTOR_CHECKS[id].join(",")}`, exit: 0, output: checks.map((c) => `${c.id}: ${c.summary}`).join("\n") }] });
    }
    return ready;
  }, [api, patch]);

  useEffect(() => {
    void readiness().catch(() => {});
  }, [readiness]);

  const runReport = async (id: StepId, call: () => Promise<Report>): Promise<boolean> => {
    patch(id, { phase: "running", summary: RUNNING[id] });
    let report: Report;
    try {
      report = await call();
    } catch {
      patch(id, { phase: "failed", summary: "Não consegui rodar o comando do Wisp.", details: [] });
      return false;
    }
    patch(id, { phase: report.status, summary: sentence(report.summary), details: report.details });
    return report.status === "done" || report.status === "skipped";
  };

  const login = async (): Promise<boolean> => {
    patch("login", { phase: "running", summary: RUNNING.login, details: [] });
    const opened = await api.post<{ ok: boolean; error?: string; command?: string }>("/setup/login", { engine: "claude" }).catch(() => null);
    if (!opened?.ok) {
      patch("login", { phase: "failed", summary: opened?.error ?? "Não consegui abrir o terminal do login.", details: [] });
      return false;
    }
    const details = [{ command: opened.command ?? "claude auth login", exit: 0, output: "terminal aberto; o Wisp confere o login a cada poucos segundos" }];
    patch("login", { details });
    const until = Date.now() + WIZARD_LOGIN_TIMEOUT_MS;
    while (live.current && Date.now() < until) {
      await sleep(WIZARD_LOGIN_POLL_MS);
      const report = await api.get<DoctorReport>("/doctor", { only: "claude_login" }).catch(() => null);
      if (report?.checks.find((c) => c.id === "claude_login")?.ok) {
        patch("login", { phase: "done", summary: "Você está dentro do Claude", details });
        return true;
      }
    }
    patch("login", { phase: "failed", summary: "O login não apareceu em 10 minutos. Conecte de novo quando quiser.", details });
    return false;
  };

  const start = async () => {
    if (running) return;
    setRunning(true);
    setProblem(null);
    setAllDone(false);
    try {
      const ready = await readiness();
      for (const id of ORDER) {
        if (ready[id]) continue;
        let ok: boolean;
        if (id === "login") ok = await login();
        else if (id === "profile") ok = await runReport(id, () => api.post<Report>("/profile", { name, user_name: user }));
        else ok = await runReport(id, () => api.post<Report>(`/setup/${id}`));
        if (!ok) {
          setProblem(id === "system" ? "Termine o que o instalador pediu e toque em Tentar de novo." : "Este passo não terminou. Toque em Tentar de novo.");
          return;
        }
      }
      await api.post("/setup/finish");
      setAllDone(true);
    } catch {
      setProblem("Não consegui falar com o Wisp. Tente de novo.");
    } finally {
      if (live.current) setRunning(false);
    }
  };

  const failed = ORDER.some((id) => steps[id].phase === "failed" || steps[id].phase === "needs_user");
  const needsProfile = steps.profile.phase !== "done" && steps.profile.phase !== "skipped";
  const canStart = !running && (!needsProfile || (name.trim() !== "" && user.trim() !== ""));

  return (
    <TabCard title="Configurar o Wisp" icon={GearIcon}>
      <div className={styles.scroll}>
        <Group title="O que o Wisp confere" caption="Cada passo mostra o que realmente rodou em “detalhes”. Começar só refaz o que faltar.">
          <ol className={styles.steps}>
            {ORDER.map((id) => (
              <li key={id} className={styles.step}>
                <div className={styles.stepHead}>
                  <span className={`${styles.stepIcon} ${TONE[steps[id].phase]}`} aria-label={steps[id].phase}>{ICON[steps[id].phase]}</span>
                  <span className={styles.title}>{TITLES[id]}</span>
                  <span style={{ flex: 1 }} />
                  {steps[id].details.length > 0 && <Button onClick={() => setOpen(open === id ? null : id)}>{open === id ? "ocultar detalhes" : "detalhes"}</Button>}
                </div>
                {steps[id].summary && <span className={steps[id].phase === "failed" ? styles.error : styles.detail}>{steps[id].summary}</span>}
                {open === id && (
                  <pre className={styles.log} aria-label={`Detalhes: ${TITLES[id]}`}>
                    {steps[id].details.map((d) => `$ ${d.command}  (saída ${d.exit})${d.output ? `\n${d.output}` : ""}`).join("\n\n")}
                  </pre>
                )}
              </li>
            ))}
          </ol>
        </Group>
        {needsProfile && (
          <Group title="Seu perfil" caption="O nome do seu Wisp e como ele chama você.">
            <Row title="Nome do seu Wisp"><TextInput aria-label="Nome do seu Wisp" value={name} onChange={(e) => setName(e.target.value)} /></Row>
            <Divider />
            <Row title="Como o Wisp chama você"><TextInput aria-label="Como o Wisp chama você" value={user} onChange={(e) => setUser(e.target.value)} /></Row>
          </Group>
        )}
        {allDone && <Detail text="Tudo pronto." />}
        {allDone && <TelegramGroup optional />}
        {problem && <InlineError text={problem} />}
        <div className={styles.controls}>
          {onClose && !running && <Button onClick={onClose}>Voltar</Button>}
          {allDone ? (
            <Button kind="accent" onClick={onFinish}>Abrir o Wisp</Button>
          ) : (
            <Button kind="accent" disabled={!canStart} onClick={() => void start()}>
              {failed ? "Tentar de novo" : "Começar"}
            </Button>
          )}
        </div>
      </div>
    </TabCard>
  );
}
