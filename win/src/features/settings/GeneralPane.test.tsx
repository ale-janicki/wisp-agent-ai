import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { GeneralPane, TelegramGroup } from "./GeneralPane";
import { loginSentence, type LoginItemApi } from "./loginItem";
import { baseState, renderWith, report, type Routes } from "./testkit";
import type { LoginStatus } from "./types";

const lessons = { lessons: [{ number: 1, rule: "responda curto", date: "2025-01-02", origin: "conversa", learned_alone: false }, { number: 2, rule: "sempre em pt", date: null, origin: "colheita", learned_alone: true }], pending: [{ number: 1, rule: "use tabelas", date: "2025-02-01", origin: "colheita", learned_alone: true }] };
const base = { "GET /api/settings/lessons": () => lessons, "GET /api/settings/telegram": () => ({ configured: false }) };
const login = (status: LoginStatus): LoginItemApi & { set: ReturnType<typeof vi.fn> } => ({ available: true, status: async () => status, set: vi.fn(async (on: boolean) => ({ state: on ? "enabled" : "disabled", error: null }) as LoginStatus) });
const show = (routes: Routes = base, over = {}, item: LoginItemApi = login({ state: "disabled", error: null })) =>
  renderWith(routes, <GeneralPane state={baseState(over)} reload={async () => {}} openSetup={() => {}} loginItem={item} />);

describe("Geral: abrir ao ligar o Windows", () => {
  it("each state has its own sentence", () => {
    expect(loginSentence({ state: "enabled", error: null }, null)).toBe("O Wisp abre sozinho quando você entra no Windows.");
    expect(loginSentence({ state: "disabled", error: null }, null)).toBe("O Wisp não abre sozinho ao ligar o Windows.");
    expect(loginSentence({ state: "turned_off_by_user", error: null }, null)).toContain("Gerenciador de Tarefas");
    expect(loginSentence(null, "falhou")).toBe("falhou");
  });

  it("the switch reflects the Run key and turning it on goes through the app command", async () => {
    const item = login({ state: "disabled", error: null });
    show(base, {}, item);
    const toggle = screen.getByRole("switch", { name: "Abrir ao ligar o Windows" });
    await waitFor(() => expect(toggle).toHaveAttribute("aria-checked", "false"));
    await userEvent.click(toggle);
    expect(item.set).toHaveBeenCalledWith(true);
    await waitFor(() => expect(toggle).toHaveAttribute("aria-checked", "true"));
    expect(screen.getByText("O Wisp abre sozinho quando você entra no Windows.")).toBeInTheDocument();
  });

  it("an error from the registry write is shown in red text, not swallowed", async () => {
    const item = login({ state: "disabled", error: null });
    item.set.mockRejectedValueOnce("acesso negado");
    show(base, {}, item);
    await userEvent.click(screen.getByRole("switch", { name: "Abrir ao ligar o Windows" }));
    expect(await screen.findByText("Não consegui ajustar a abertura ao ligar o Windows: acesso negado")).toBeInTheDocument();
  });

  it("outside the installed app the switch is off and says why", () => {
    show(base, {}, { available: false, status: async () => ({ state: "disabled", error: null }), set: async () => ({ state: "enabled", error: null }) });
    expect(screen.getByRole("switch", { name: "Abrir ao ligar o Windows" })).toBeDisabled();
    expect(screen.getByText("Disponível quando o Wisp estiver instalado.")).toBeInTheDocument();
  });
});

describe("Geral: pastas", () => {
  it("shows the default Wisp folder as padrão and lists what is inside", () => {
    show();
    expect(screen.getByText("~/Wisp (padrão)")).toBeInTheDocument();
    expect(screen.getByText(/conversas\/\s+o histórico de cada conversa/)).toBeInTheDocument();
  });

  it("Trocar… applies the typed path through config set and closes on success", async () => {
    const view = show({ ...base, "POST /api/settings/path": () => report("config", "done", "caminho salvo") });
    await userEvent.click(screen.getAllByRole("button", { name: "Trocar…" })[0]!);
    const input = screen.getByLabelText("Caminho: Pasta do Wisp");
    await userEvent.clear(input);
    await userEvent.type(input, "D:\\Wisp");
    await userEvent.click(screen.getByRole("button", { name: "Aplicar" }));
    await waitFor(() => expect(view.posts("/api/settings/path")[0]?.body).toEqual({ key: "wisp_dir", value: "D:\\Wisp" }));
    await waitFor(() => expect(screen.queryByLabelText("Caminho: Pasta do Wisp")).not.toBeInTheDocument());
  });

  it("a rejected path keeps the field open with the CLI's sentence", async () => {
    show({ ...base, "POST /api/settings/path": () => report("config", "failed", "use um caminho completo (começando com / ou ~)") });
    await userEvent.click(screen.getAllByRole("button", { name: "Trocar…" })[0]!);
    await userEvent.click(screen.getByRole("button", { name: "Aplicar" }));
    expect(await screen.findByText("Use um caminho completo (começando com / ou ~)")).toBeInTheDocument();
    expect(screen.getByLabelText("Caminho: Pasta do Wisp")).toBeInTheDocument();
  });
});

describe("Geral: brain", () => {
  it("offers Criar o cérebro only while the folder is missing and reports a failure", async () => {
    const view = show({ ...base, "POST /api/settings/brain/create": () => ({ ok: false, error: "Falta o Git" }) }, { paths: { ...baseState().paths, brain: null, brain_missing: true } });
    expect(screen.getByText("Nenhuma pasta escolhida")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Criar o cérebro" }));
    expect(await screen.findByText("Falta o Git")).toBeInTheDocument();
    expect(view.posts("/api/settings/brain/create")).toHaveLength(1);
  });

  it("no Criar o cérebro when it exists", () => {
    show();
    expect(screen.queryByRole("button", { name: "Criar o cérebro" })).not.toBeInTheDocument();
  });

  it("the learn switch posts the new value", async () => {
    const view = show({ ...base, "POST /api/settings/learn": () => ({ ok: true }) });
    await userEvent.click(screen.getByRole("switch", { name: "Aprender com as conversas" }));
    await waitFor(() => expect(view.posts("/api/settings/learn")[0]?.body).toEqual({ on: false }));
  });

  it("pending lessons are confirmed or discarded and learned ones removed, by number", async () => {
    const view = show({ ...base, "POST /api/settings/lessons/confirm": () => ({ ok: true }), "POST /api/settings/lessons/discard": () => ({ ok: true }), "POST /api/settings/lessons/forget": () => ({ ok: true }) });
    expect(await screen.findByText("Quer aprender, esperando você confirmar · 2025-02-01")).toBeInTheDocument();
    expect(screen.getByText("aprendido sozinho")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Confirmar" }));
    await userEvent.click(screen.getByRole("button", { name: "Descartar" }));
    await userEvent.click(screen.getAllByRole("button", { name: "Remover" })[1]!);
    await waitFor(() => expect(view.posts("/api/settings/lessons/forget")[0]?.body).toEqual({ number: 2 }));
    expect(view.posts("/api/settings/lessons/confirm")[0]?.body).toEqual({ number: 1 });
    expect(view.posts("/api/settings/lessons/discard")[0]?.body).toEqual({ number: 1 });
  });
});

describe("Telegram", () => {
  it("the token field is a password field and Conectar needs a token", async () => {
    renderWith(base, <GeneralPaneTelegram />);
    const token = await screen.findByLabelText("Token do bot");
    expect(token).toHaveAttribute("type", "password");
    expect(screen.getByRole("button", { name: "Conectar Telegram" })).toBeDisabled();
  });

  it("Conectar sends the token, then offers Procurar o grupo", async () => {
    const shown = renderWith({ ...base, "POST /api/settings/telegram": () => ({ ok: true, message: "Mande oi no grupo", token_stored: true, configured: false }) }, <GeneralPaneTelegram />);
    await userEvent.type(await screen.findByLabelText("Token do bot"), "123:abc");
    await userEvent.click(screen.getByRole("button", { name: "Conectar Telegram" }));
    expect(await screen.findByText("Token guardado")).toBeInTheDocument();
    expect(screen.getByText("Mande oi no grupo")).toBeInTheDocument();
    expect(shown.posts("/api/settings/telegram")[0]?.body).toEqual({ action: "connect", token: "123:abc" });
    expect(screen.queryByDisplayValue("123:abc")).not.toBeInTheDocument();
  });

  it("when configured it offers Conferir o bot and Desconectar; a failed answer is red text", async () => {
    const shown = renderWith(
      { "GET /api/settings/telegram": () => ({ configured: true }), "POST /api/settings/telegram": () => ({ ok: false, message: "Não consegui falar com o Telegram. Tente de novo.", token_stored: false, configured: true }) },
      <GeneralPaneTelegram />,
    );
    expect(await screen.findByText("Telegram conectado")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Desconectar" }));
    expect(await screen.findByText("Não consegui falar com o Telegram. Tente de novo.")).toBeInTheDocument();
    expect(shown.posts("/api/settings/telegram")[0]?.body).toEqual({ action: "disconnect" });
  });
});

const GeneralPaneTelegram = () => <TelegramGroup />;
