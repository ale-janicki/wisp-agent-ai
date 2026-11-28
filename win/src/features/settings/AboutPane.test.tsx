import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AboutPane } from "./AboutPane";
import { baseState, renderWith } from "./testkit";

const update = { version: "0.2.0", tag: "windows-v0.2.0", notes_url: "https://github.com/o/r/releases/tag/windows-v0.2.0", asset: "Wisp-Setup.exe", size: 9, verified: true };

beforeEach(() => localStorage.clear());

describe("Sobre", () => {
  it("checks once when opened and says when the app is current", async () => {
    const view = renderWith({ "GET /api/settings/updates/check": () => ({ ok: true, available: null }) }, <AboutPane state={baseState()} />);
    expect(await screen.findByText("Você está na versão mais nova.")).toBeInTheDocument();
    expect(screen.getByText("Versão 0.1.0")).toBeInTheDocument();
    expect(view.calls.filter((c) => c.path === "/api/settings/updates/check")).toHaveLength(1);
  });

  it("an available windows pre-release is offered with notes and a download button", async () => {
    renderWith({ "GET /api/settings/updates/check": () => ({ ok: true, available: update }) }, <AboutPane state={baseState()} />);
    expect(await screen.findByText("A 0.2.0 já está disponível.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Ver novidades" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Baixar e instalar" })).toBeEnabled();
  });

  it("Baixar e instalar sends nothing about the file and says the installer opened", async () => {
    const view = renderWith(
      { "GET /api/settings/updates/check": () => ({ ok: true, available: update }), "POST /api/settings/updates/install": () => ({ ok: true, run: true, path: "C:/d/a.exe" }) },
      <AboutPane state={baseState()} />,
    );
    await userEvent.click(await screen.findByRole("button", { name: "Baixar e instalar" }));
    expect(await screen.findByText("O instalador abriu. Feche o Wisp e siga os passos dele para atualizar.")).toBeInTheDocument();
    expect(view.posts("/api/settings/updates/install")[0]?.body).toEqual({});
  });

  it("a release without a published digest is downloaded but not run, and the user is told", async () => {
    renderWith(
      { "GET /api/settings/updates/check": () => ({ ok: true, available: { ...update, verified: false } }), "POST /api/settings/updates/install": () => ({ ok: true, run: false, path: "C:/d/a.exe" }) },
      <AboutPane state={baseState()} />,
    );
    await userEvent.click(await screen.findByRole("button", { name: "Baixar" }));
    expect(await screen.findByText(/não abri\. A pasta abriu para você decidir/)).toBeInTheDocument();
  });

  it("a digest mismatch is shown and nothing is opened", async () => {
    renderWith(
      { "GET /api/settings/updates/check": () => ({ ok: true, available: update }), "POST /api/settings/updates/install": () => ({ ok: false, error: "O arquivo baixado não confere com o publicado; não foi aberto." }) },
      <AboutPane state={baseState()} />,
    );
    await userEvent.click(await screen.findByRole("button", { name: "Baixar e instalar" }));
    expect(await screen.findByText("O arquivo baixado não confere com o publicado; não foi aberto.")).toBeInTheDocument();
  });

  it("offline shows the Mac-style retry sentence", async () => {
    renderWith({ "GET /api/settings/updates/check": () => ({ ok: false, error: "Não consegui verificar as atualizações. Tente de novo." }) }, <AboutPane state={baseState()} />);
    expect(await screen.findByText("Não consegui verificar as atualizações. Tente de novo.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Verificar agora" })).toBeInTheDocument();
  });

  it("with automatic checks off nothing is fetched until Verificar agora", async () => {
    localStorage.setItem("wisp.updates.auto", "off");
    const view = renderWith({ "GET /api/settings/updates/check": () => ({ ok: true, available: null }) }, <AboutPane state={baseState()} />);
    expect(screen.getByRole("switch", { name: "Verificar automaticamente" })).toHaveAttribute("aria-checked", "false");
    expect(view.calls).toHaveLength(0);
    await userEvent.click(screen.getByRole("button", { name: "Verificar agora" }));
    await waitFor(() => expect(view.calls).toHaveLength(1));
  });

  it("Abrir no GitHub goes through the sidecar's allow-listed opener", async () => {
    const view = renderWith({ "GET /api/settings/updates/check": () => ({ ok: true, available: null }), "POST /api/settings/open": () => ({ ok: true }) }, <AboutPane state={baseState()} />);
    await userEvent.click(screen.getByRole("button", { name: "Abrir no GitHub" }));
    await waitFor(() => expect(view.posts("/api/settings/open")[0]?.body).toEqual({ url: "https://github.com/ale-janicki/wisp-agent-ai" }));
  });
});
