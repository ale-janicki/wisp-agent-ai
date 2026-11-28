import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SetupWizard, WIZARD_LOGIN_POLL_MS } from "./SetupWizard";
import { baseState, check, renderWith, report } from "./testkit";

const missing = (...ids: string[]) => ({ checks: ["git", "claude", "claude_login", "brain", "harness", "profile"].map((id) => check(id, !ids.includes(id))) });
const step = (title: string) => screen.getByText(title).closest("li")!;

afterEach(() => vi.useRealTimers());

describe("Configurar o Wisp", () => {
  it("lists the five steps, marking the ones the doctor already finds ready", async () => {
    renderWith({ "GET /api/settings/doctor": () => missing("brain", "harness", "profile") }, <SetupWizard state={baseState({ setup_finished: false })} onFinish={() => {}} />);
    await waitFor(() => expect(within(step("Git e Claude Code")).getByLabelText("done")).toBeInTheDocument());
    expect(within(step("Login no Claude")).getByLabelText("done")).toBeInTheDocument();
    expect(within(step("Seu cérebro")).getByLabelText("idle")).toBeInTheDocument();
  });

  it("a ready step's detalhes show the doctor check that proved it", async () => {
    renderWith({ "GET /api/settings/doctor": () => missing() }, <SetupWizard state={baseState()} onFinish={() => {}} />);
    await waitFor(() => expect(within(step("Seu cérebro")).getByLabelText("done")).toBeInTheDocument());
    await userEvent.click(within(step("Seu cérebro")).getByRole("button", { name: "detalhes" }));
    expect(screen.getByLabelText("Detalhes: Seu cérebro")).toHaveTextContent("$ wisp doctor --json --only brain (saída 0)");
    expect(screen.getByLabelText("Detalhes: Seu cérebro")).toHaveTextContent("brain: brain ok");
  });

  it("Começar runs only what is missing, in order, then finishes and offers Abrir o Wisp", async () => {
    const onFinish = vi.fn();
    const view = renderWith(
      {
        "GET /api/settings/doctor": () => missing("brain", "harness", "profile"),
        "POST /api/settings/setup/brain": () => report("brain", "done", "cérebro criado"),
        "POST /api/settings/setup/harness": () => report("harness", "done", "ferramentas instaladas"),
        "POST /api/settings/profile": () => report("profile", "done", "perfil pronto"),
        "POST /api/settings/setup/finish": () => ({ ok: true }),
        "GET /api/settings/telegram": () => ({ configured: false }),
      },
      <SetupWizard state={baseState({ setup_finished: false })} onFinish={onFinish} />,
    );
    await waitFor(() => expect(within(step("Login no Claude")).getByLabelText("done")).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Começar" }));
    await userEvent.click(await screen.findByRole("button", { name: "Abrir o Wisp" }));
    expect(onFinish).toHaveBeenCalled();
    const order = view.calls.filter((c) => c.method === "POST").map((c) => c.path);
    expect(order).toEqual(["/api/settings/setup/brain", "/api/settings/setup/harness", "/api/settings/profile", "/api/settings/setup/finish"]);
    expect(view.posts("/api/settings/profile")[0]?.body).toEqual({ name: "Wisp", user_name: "Bia" });
    expect(screen.getByRole("region", { name: "Telegram (opcional)" })).toBeInTheDocument();
  });

  it("each finished step's detalhes show what really ran", async () => {
    renderWith(
      { "GET /api/settings/doctor": () => missing("brain"), "POST /api/settings/setup/brain": () => report("brain", "done", "cérebro criado", { details: [{ command: "git init -b main", exit: 0, output: "Initialized" }, { command: "git add -- index.md", exit: 0, output: "" }] }), "POST /api/settings/setup/finish": () => ({ ok: true }), "GET /api/settings/telegram": () => ({ configured: false }) },
      <SetupWizard state={baseState()} onFinish={() => {}} />,
    );
    await waitFor(() => expect(within(step("Login no Claude")).getByLabelText("done")).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Começar" }));
    await waitFor(() => expect(within(step("Seu cérebro")).getByLabelText("done")).toBeInTheDocument());
    expect(within(step("Seu cérebro")).getByText("Cérebro criado")).toBeInTheDocument();
    await userEvent.click(within(step("Seu cérebro")).getByRole("button", { name: "detalhes" }));
    expect(screen.getByLabelText("Detalhes: Seu cérebro")).toHaveTextContent("$ git init -b main (saída 0)");
    expect(screen.getByLabelText("Detalhes: Seu cérebro")).toHaveTextContent("Initialized");
    expect(screen.getByLabelText("Detalhes: Seu cérebro")).toHaveTextContent("$ git add -- index.md (saída 0)");
  });

  it("a failed step stops the run, shows its sentence and offers Tentar de novo", async () => {
    const view = renderWith(
      { "GET /api/settings/doctor": () => missing("git", "claude", "claude_login", "brain"), "POST /api/settings/setup/system": () => report("system", "failed", "não consegui instalar o Claude") },
      <SetupWizard state={baseState()} onFinish={() => {}} />,
    );
    await waitFor(() => expect(within(step("Seu perfil")).getByLabelText("done")).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Começar" }));
    expect(await screen.findByText("Não consegui instalar o Claude")).toBeInTheDocument();
    expect(within(step("Git e Claude Code")).getByLabelText("failed")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Tentar de novo" })).toBeInTheDocument();
    expect(view.posts("/api/settings/setup/brain")).toHaveLength(0);
  });

  it("Git waiting on the user (needs_user) halts there with the installer's message", async () => {
    renderWith(
      { "GET /api/settings/doctor": () => missing("git", "brain"), "POST /api/settings/setup/system": () => report("system", "needs_user", "Termine a instalação do Git na janela que abriu", { data: { waiting: "git" } }) },
      <SetupWizard state={baseState()} onFinish={() => {}} />,
    );
    await waitFor(() => expect(within(step("Seu perfil")).getByLabelText("done")).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Começar" }));
    expect(await screen.findByText("Termine a instalação do Git na janela que abriu")).toBeInTheDocument();
    expect(within(step("Git e Claude Code")).getByLabelText("needs_user")).toBeInTheDocument();
  });

  it("the profile step needs both names before Começar is allowed", async () => {
    renderWith({ "GET /api/settings/doctor": () => missing("profile") }, <SetupWizard state={baseState({ profile: { name: "Wisp", user: "", avatar: null } })} onFinish={() => {}} />);
    await waitFor(() => expect(within(step("Seu cérebro")).getByLabelText("done")).toBeInTheDocument());
    const start = screen.getByRole("button", { name: "Começar" });
    expect(start).toBeDisabled();
    await userEvent.type(screen.getByLabelText("Como o Wisp chama você"), "Bia");
    expect(start).toBeEnabled();
  });

  it("the login step opens the console and finishes when the doctor sees the login", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    let loggedIn = false;
    const view = renderWith(
      {
        "GET /api/settings/doctor": () => (loggedIn ? missing() : missing("claude_login")),
        "POST /api/settings/setup/login": () => ({ ok: true, command: "claude auth login" }),
        "POST /api/settings/setup/finish": () => ({ ok: true }),
        "GET /api/settings/telegram": () => ({ configured: false }),
      },
      <SetupWizard state={baseState()} onFinish={() => {}} />,
    );
    await waitFor(() => expect(within(step("Git e Claude Code")).getByLabelText("done")).toBeInTheDocument());
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    await user.click(screen.getByRole("button", { name: "Começar" }));
    await waitFor(() => expect(within(step("Login no Claude")).getByLabelText("running")).toBeInTheDocument());
    expect(view.posts("/api/settings/setup/login")[0]?.body).toEqual({ engine: "claude" });
    loggedIn = true;
    await act(async () => {
      await vi.advanceTimersByTimeAsync(WIZARD_LOGIN_POLL_MS + 50);
    });
    await waitFor(() => expect(within(step("Login no Claude")).getByLabelText("done")).toBeInTheDocument());
    expect(await screen.findByRole("button", { name: "Abrir o Wisp" })).toBeInTheDocument();
  });

  it("a login console that does not open fails the step with the sidecar's sentence", async () => {
    renderWith(
      { "GET /api/settings/doctor": () => missing("claude_login"), "POST /api/settings/setup/login": () => ({ ok: false, error: "O Claude não está instalado." }) },
      <SetupWizard state={baseState()} onFinish={() => {}} />,
    );
    await waitFor(() => expect(within(step("Git e Claude Code")).getByLabelText("done")).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Começar" }));
    expect(await screen.findByText("O Claude não está instalado.")).toBeInTheDocument();
  });

  it("Voltar is offered only when the wizard was opened on purpose", async () => {
    const onClose = vi.fn();
    renderWith({ "GET /api/settings/doctor": () => missing() }, <SetupWizard state={baseState()} onFinish={() => {}} onClose={onClose} />);
    await userEvent.click(screen.getByRole("button", { name: "Voltar" }));
    expect(onClose).toHaveBeenCalled();
  });
});
