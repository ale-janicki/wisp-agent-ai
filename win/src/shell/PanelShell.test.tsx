import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { features } from "../features/registry";
import { COMING_SOON } from "../features/ComingSoon";
import { FakeEventSource, fakeFetch } from "../test/fakes";
import { WispSession } from "../WispSession";
import { PanelShell } from "./PanelShell";
import { SELECTED_KEY } from "./useSelectedFeature";

const info = { port: 4242, token: "tok" };
const status = { label: "Pronto", tone: "ok" as const };

const MAC_TABS = [
  ["home", "Início"],
  ["conversa", "Conversa"],
  ["brain", "Brain"],
  ["tasks", "Tarefas"],
  ["agenda", "Agenda"],
  ["meetings", "Reuniões"],
  ["music", "Música"],
  ["clipboard", "Copiados"],
  ["terminal", "Terminal"],
  ["mymac", "My Mac"],
  ["settings", "Ajustes"],
];

function Shell({ onToggleWindow = () => {} }: { onToggleWindow?: () => void }) {
  const [draft, setDraft] = useState("");
  const { impl } = fakeFetch({ "GET /conversations": () => ({ items: [] }) });
  const deps = { fetchImpl: impl, createSource: (u: string) => new FakeEventSource(u) as unknown as EventSource };
  return (
    <WispSession info={info} deps={deps} onSummary={() => {}}>
      {(session, bus) => (
        <PanelShell
          value={{ info, bus, session, draft, setDraft, focusComposer: false }}
          windowed={false}
          onToggleWindow={onToggleWindow}
          status={status}
        />
      )}
    </WispSession>
  );
}

beforeEach(() => {
  FakeEventSource.reset();
  localStorage.clear();
});

const sidebar = () => screen.getByRole("navigation", { name: "Abas" });

describe("registry and sidebar", () => {
  it("has the Mac's tabs in the Mac's order, ids unique", () => {
    expect(features.map((f) => [f.id, f.label])).toEqual(MAC_TABS);
    expect(new Set(features.map((f) => f.id)).size).toBe(features.length);
    expect(features.filter((f) => f.hasListColumn).map((f) => f.id)).toEqual(["conversa", "meetings", "terminal"]);
    expect(features.filter((f) => f.placement === "bottom").map((f) => f.id)).toEqual(["settings"]);
  });

  it("renders every tab on click, starts on Início, and the others say they are coming", async () => {
    render(<Shell />);
    expect(screen.getByRole("main", { name: "Início" })).toBeInTheDocument();
    for (const f of features) {
      await userEvent.click(within(sidebar()).getByRole("button", { name: f.label }));
      const main = screen.getByRole("main", { name: f.label });
      expect(within(sidebar()).getByRole("button", { name: f.label })).toHaveAttribute("aria-current", "page");
      if (f.id === "conversa") expect(within(main).getByRole("button", { name: "Nova conversa" })).toBeInTheDocument();
      else expect(within(main).getByText(COMING_SOON)).toBeInTheDocument();
    }
  });

  it("keeps the selected tab in localStorage and reopens on it; old Mac names open the new tab", async () => {
    const first = render(<Shell />);
    await userEvent.click(screen.getByRole("button", { name: "Agenda" }));
    expect(localStorage.getItem(SELECTED_KEY)).toBe("agenda");
    first.unmount();
    render(<Shell />);
    expect(screen.getByRole("main", { name: "Agenda" })).toBeInTheDocument();
  });

  it.each([
    ["memory", "Brain"],
    ["routines", "Ajustes"],
    ["no-such-tab", "Início"],
  ])("a saved %s opens %s", (saved, label) => {
    localStorage.setItem(SELECTED_KEY, saved);
    render(<Shell />);
    expect(screen.getByRole("main", { name: label })).toBeInTheDocument();
  });

  it("folds into the icon rail on tabs with a list column and floats open on hover", async () => {
    render(<Shell />);
    expect(sidebar()).toHaveAttribute("data-compact", "false");
    expect(within(sidebar()).getByText("Brain")).toBeInTheDocument();

    for (const label of ["Conversa", "Reuniões", "Terminal"]) {
      await userEvent.click(within(sidebar()).getByRole("button", { name: label }));
      await userEvent.unhover(sidebar());
      expect(sidebar()).toHaveAttribute("data-compact", "true");
      expect(within(sidebar()).queryByText(label)).toBeNull();
      expect(within(sidebar()).getByRole("button", { name: label })).toHaveAttribute("title", label);
    }

    await userEvent.hover(sidebar());
    expect(sidebar()).toHaveAttribute("data-compact", "false");
    expect(within(sidebar()).getByText("Terminal")).toBeInTheDocument();
    await userEvent.unhover(sidebar());
    expect(sidebar()).toHaveAttribute("data-compact", "true");

    await userEvent.hover(sidebar());
    await userEvent.click(within(sidebar()).getByRole("button", { name: "Tarefas" }));
    expect(sidebar()).toHaveAttribute("data-compact", "false");
  });

  it("the window button asks the shell to switch mode", async () => {
    const toggle = vi.fn();
    render(<Shell onToggleWindow={toggle} />);
    await userEvent.click(screen.getByRole("button", { name: "Abrir em janela" }));
    expect(toggle).toHaveBeenCalledOnce();
  });
});
