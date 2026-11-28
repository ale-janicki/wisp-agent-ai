import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { ModelPane } from "./ModelPane";
import { baseState, check, renderWith, report } from "./testkit";

const doctor = (...checks: ReturnType<typeof check>[]) => ({ checks });
const loggedIn = doctor(check("claude", true), check("claude_login", true), check("codex", false), check("codex_login", false));

describe("Modelo", () => {
  it("lists the three engines with the Mac's wording and the status of each", async () => {
    renderWith({ "GET /api/settings/doctor": () => loggedIn }, <ModelPane state={baseState()} reload={async () => {}} />);
    expect(screen.getByRole("radio", { name: /^Claude/ })).toHaveAttribute("aria-checked", "true");
    expect(await screen.findByText("Codex não está instalado neste PC.")).toBeInTheDocument();
    expect(screen.getByText("É o motor padrão do Wisp.")).toBeInTheDocument();
    expect(screen.getByRole("radio", { name: /^IA local/ })).toBeDisabled();
    expect(screen.getByText("Conectado")).toBeInTheDocument();
  });

  it("switching the engine runs config set engine through the sidecar and reloads", async () => {
    const reload = vi.fn(async () => {});
    const doctorRoute = vi.fn(() => doctor(check("codex", true), check("codex_login", true), check("claude", true), check("claude_login", true)));
    const view = renderWith(
      { "GET /api/settings/doctor": doctorRoute, "POST /api/settings/engine": () => report("config", "done", "motor salvo") },
      <ModelPane state={baseState()} reload={reload} />,
    );
    expect(await screen.findByText("Codex instalado e com login feito.")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("radio", { name: /^Codex/ }));
    await waitFor(() => expect(reload).toHaveBeenCalled());
    expect(view.posts("/api/settings/engine")[0]?.body).toEqual({ engine: "codex" });
  });

  it("shows the CLI's own sentence when the engine switch fails", async () => {
    renderWith(
      { "GET /api/settings/doctor": () => loggedIn, "POST /api/settings/engine": () => report("config", "failed", "o harness não sincronizou") },
      <ModelPane state={baseState()} reload={async () => {}} />,
    );
    await userEvent.click(await screen.findByRole("radio", { name: /^Codex/ }));
    expect(await screen.findByText("O harness não sincronizou")).toBeInTheDocument();
  });

  it("when Claude is not installed it offers the PowerShell install command", async () => {
    renderWith({ "GET /api/settings/doctor": () => doctor(check("claude", false), check("claude_login", false)) }, <ModelPane state={baseState()} reload={async () => {}} />);
    expect(await screen.findByText("Claude não está instalado neste PC.")).toBeInTheDocument();
    expect(screen.getByText("irm https://claude.ai/install.ps1 | iex")).toBeInTheDocument();
  });

  it("Conectar Claude opens the login console and then waits for it", async () => {
    const view = renderWith(
      { "GET /api/settings/doctor": () => doctor(check("claude", true), check("claude_login", false)), "POST /api/settings/setup/login": () => ({ ok: true, command: "claude auth login" }) },
      <ModelPane state={baseState()} reload={async () => {}} />,
    );
    await userEvent.click(await screen.findByRole("button", { name: "Conectar Claude" }));
    expect(await screen.findByText("Esperando o login no terminal…")).toBeInTheDocument();
    expect(view.posts("/api/settings/setup/login")[0]?.body).toEqual({ engine: "claude" });
  });

  it("a login console that cannot open is reported", async () => {
    renderWith(
      { "GET /api/settings/doctor": () => doctor(check("claude", true), check("claude_login", false)), "POST /api/settings/setup/login": () => ({ ok: false, error: "Não consegui abrir o terminal do login." }) },
      <ModelPane state={baseState()} reload={async () => {}} />,
    );
    await userEvent.click(await screen.findByRole("button", { name: "Conectar Claude" }));
    expect(await screen.findByText("Não consegui abrir o terminal do login.")).toBeInTheDocument();
  });
});

describe("Permissões", () => {
  const permissionPost = () => ({ ok: true, error: null });

  it("names the active engine and shows its own wording for each choice", async () => {
    renderWith({ "GET /api/settings/doctor": () => loggedIn }, <ModelPane state={baseState({ engine: "codex" })} reload={async () => {}} />);
    expect(screen.getByRole("region", { name: "Permissões do Codex" })).toBeInTheDocument();
    expect(screen.getByText(/O Codex não consegue pedir aprovação aqui/)).toBeInTheDocument();
  });

  it("picking Automático saves at once", async () => {
    const view = renderWith({ "GET /api/settings/doctor": () => loggedIn, "POST /api/settings/permission": permissionPost }, <ModelPane state={baseState()} reload={async () => {}} />);
    await userEvent.click(screen.getByRole("radio", { name: /Automático/ }));
    await waitFor(() => expect(view.posts("/api/settings/permission")[0]?.body).toEqual({ choice: "auto" }));
  });

  it("Sem pedir asks first and only Usar sem pedir saves it", async () => {
    const view = renderWith({ "GET /api/settings/doctor": () => loggedIn, "POST /api/settings/permission": permissionPost }, <ModelPane state={baseState()} reload={async () => {}} />);
    await userEvent.click(screen.getByRole("radio", { name: /Sem pedir/ }));
    expect(screen.getByText(/Só as regras de bloqueio do Claude e os hooks continuam valendo/)).toBeInTheDocument();
    expect(view.posts("/api/settings/permission")).toHaveLength(0);
    await userEvent.click(screen.getByRole("button", { name: "Usar sem pedir" }));
    await waitFor(() => expect(view.posts("/api/settings/permission")[0]?.body).toEqual({ choice: "bypassPermissions" }));
  });

  it("Cancelar leaves the mode alone", async () => {
    const view = renderWith({ "GET /api/settings/doctor": () => loggedIn }, <ModelPane state={baseState()} reload={async () => {}} />);
    await userEvent.click(screen.getByRole("radio", { name: /Sem pedir/ }));
    await userEvent.click(screen.getByRole("button", { name: "Cancelar" }));
    expect(screen.queryByRole("button", { name: "Usar sem pedir" })).not.toBeInTheDocument();
    expect(view.posts("/api/settings/permission")).toHaveLength(0);
  });

  it("explains where a mode that came from Claude's own settings lives", () => {
    renderWith(
      { "GET /api/settings/doctor": () => loggedIn },
      <ModelPane state={baseState({ permission: { choice: null, source: "claude", claude_mode: "acceptEdits", profile_is_link: false } })} reload={async () => {}} />,
    );
    expect(screen.getByText(/acceptEdits, sem equivalente aqui/)).toBeInTheDocument();
  });

  it("surfaces a profile that could not be written", async () => {
    renderWith(
      { "GET /api/settings/doctor": () => loggedIn, "POST /api/settings/permission": () => ({ ok: false, error: "Não consegui salvar no perfil: negado" }) },
      <ModelPane state={baseState()} reload={async () => {}} />,
    );
    await userEvent.click(screen.getByRole("radio", { name: /Automático/ }));
    expect(await screen.findByText("Não consegui salvar no perfil: negado")).toBeInTheDocument();
  });
});
