import { act, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { App } from "./App";
import { FakeEventSource, fakeFetch } from "./test/fakes";

const bridge = vi.hoisted(() => ({
  setMode: vi.fn(async () => {}),
  quit: vi.fn(async () => {}),
  readSidecar: vi.fn(async () => ({ status: "ready" as const, port: 4242, token: "tok" })),
  listenShell: vi.fn(async () => () => {}),
}));
vi.mock("./shell/bridge", () => bridge);

const { impl } = fakeFetch({ "GET /conversations": () => ({ items: [] }) });
const deps = { fetchImpl: impl, createSource: (u: string) => new FakeEventSource(u) as unknown as EventSource };

beforeEach(() => {
  vi.useFakeTimers({ shouldAdvanceTime: true });
  FakeEventSource.reset();
  bridge.setMode.mockClear();
});
afterEach(() => vi.useRealTimers());

const settle = () => act(async () => void (await vi.advanceTimersByTimeAsync(0)));

describe("shell behaviour", () => {
  it("opens on hover after the dwell, collapses 600 ms after the mouse leaves", async () => {
    render(<App deps={deps} />);
    await settle();
    const pill = screen.getByRole("button", { name: "Wisp" });
    await userEvent.hover(pill);
    await act(async () => void (await vi.advanceTimersByTimeAsync(350)));
    expect(bridge.setMode).toHaveBeenLastCalledWith("panel", false);

    const panel = screen.getByRole("navigation", { name: "Conversas" }).parentElement!;
    await userEvent.hover(panel);
    await userEvent.unhover(panel);
    await act(async () => void (await vi.advanceTimersByTimeAsync(650)));
    expect(bridge.setMode).toHaveBeenLastCalledWith("pill", false);
  });

  it("does not collapse on leave while the draft has content, but Esc collapses", async () => {
    render(<App deps={deps} />);
    await settle();
    await userEvent.click(screen.getByRole("button", { name: "Wisp" }));
    expect(bridge.setMode).toHaveBeenLastCalledWith("panel", true);
    const box = screen.getByPlaceholderText("Pergunte ao Wisp…");
    await userEvent.type(box, "rascunho");
    const panel = screen.getByRole("navigation", { name: "Conversas" }).parentElement!;
    await userEvent.unhover(panel);
    await act(async () => void (await vi.advanceTimersByTimeAsync(1000)));
    expect(bridge.setMode).toHaveBeenLastCalledWith("panel", true);

    await userEvent.keyboard("{Escape}");
    expect(bridge.setMode).toHaveBeenLastCalledWith("pill", false);
  });
});
