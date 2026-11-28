import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SECTION_KEY, SettingsTab } from "./SettingsTab";
import { baseState, check, renderWith } from "./testkit";

beforeEach(() => localStorage.clear());

const ready = { checks: ["git", "claude", "claude_login", "brain", "harness", "profile"].map((id) => check(id, true)) };

describe("Ajustes shell", () => {
  it("has the Mac's six sections and opens Aparência first", async () => {
    renderWith({ "GET /api/settings/state": () => baseState() }, <SettingsTab />);
    const tabs = await screen.findAllByRole("tab");
    expect(tabs.map((t) => t.textContent)).toEqual(["Aparência", "Modelo", "Avisos", "Automações", "Geral", "Sobre"]);
    expect(screen.getByRole("tab", { name: "Aparência" })).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("region", { name: "Perfil" })).toBeInTheDocument();
  });

  it("remembers the section the way the Mac does", async () => {
    renderWith({ "GET /api/settings/state": () => baseState(), "GET /api/settings/doctor": () => ({ checks: [] }) }, <SettingsTab />);
    await userEvent.click(await screen.findByRole("tab", { name: "Modelo" }));
    expect(localStorage.getItem(SECTION_KEY)).toBe("model");
  });

  it("reopens on the saved section", async () => {
    localStorage.setItem(SECTION_KEY, "notices");
    renderWith({ "GET /api/settings/state": () => baseState() }, <SettingsTab />);
    expect(await screen.findByRole("region", { name: "Avisos no painel" })).toBeInTheDocument();
  });

  it("says so when the sidecar cannot be read", async () => {
    renderWith({}, <SettingsTab />);
    expect(await screen.findByText("Não consegui ler os ajustes.")).toBeInTheDocument();
  });

  it("on a first run with everything already in place marks setup finished and stays on Ajustes", async () => {
    const view = renderWith(
      { "GET /api/settings/state": () => baseState({ setup_finished: false }), "GET /api/settings/doctor": () => ready, "POST /api/settings/setup/finish": () => ({ ok: true }) },
      <SettingsTab />,
    );
    await waitFor(() => expect(view.posts("/api/settings/setup/finish")).toHaveLength(1));
    expect(screen.queryByText("Configurar o Wisp")).not.toBeInTheDocument();
  });

  it("on a first run with something missing opens the wizard instead of Ajustes", async () => {
    renderWith(
      { "GET /api/settings/state": () => baseState({ setup_finished: false }), "GET /api/settings/doctor": () => ({ checks: [check("git", false), check("claude", false)] }) },
      <SettingsTab />,
    );
    expect(await screen.findByRole("region", { name: "Configurar o Wisp" })).toBeInTheDocument();
    expect(screen.queryByRole("tab")).not.toBeInTheDocument();
  });

  it("Rodar o setup de novo opens the wizard and Voltar closes it", async () => {
    localStorage.setItem(SECTION_KEY, "general");
    renderWith(
      {
        "GET /api/settings/state": () => baseState(),
        "GET /api/settings/doctor": () => ready,
        "GET /api/settings/lessons": () => ({ lessons: [], pending: [] }),
        "GET /api/settings/telegram": () => ({ configured: false }),
      },
      <SettingsTab loginItem={{ available: false, status: async () => ({ state: "disabled", error: null }), set: async () => ({ state: "enabled", error: null }) }} />,
    );
    await userEvent.click(await screen.findByRole("button", { name: "Rodar o setup de novo" }));
    expect(await screen.findByRole("region", { name: "Configurar o Wisp" })).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Voltar" }));
    expect(await screen.findByRole("tab", { name: "Geral" })).toBeInTheDocument();
  });
});
