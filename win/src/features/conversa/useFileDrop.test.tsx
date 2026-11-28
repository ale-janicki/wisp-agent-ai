import { act, render, screen } from "@testing-library/react";
import { useFileDrop } from "./useFileDrop";

type Handler = (event: { payload: { type: string; paths?: string[] } }) => void;
let handler: Handler | null = null;
const unlisten = vi.fn();

vi.mock("@tauri-apps/api/webview", () => ({
  getCurrentWebview: () => ({
    onDragDropEvent: (h: Handler) => {
      handler = h;
      return Promise.resolve(unlisten);
    },
  }),
}));

function Probe({ onPaths, enabled = true }: { onPaths: (p: string[]) => void; enabled?: boolean }) {
  const dropping = useFileDrop(onPaths, enabled);
  return <div data-testid="state">{dropping ? "dropping" : "idle"}</div>;
}

afterEach(() => {
  delete (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__;
  handler = null;
  unlisten.mockClear();
});

describe("useFileDrop", () => {
  it("does nothing outside Tauri", () => {
    render(<Probe onPaths={() => {}} />);
    expect(handler).toBeNull();
  });

  it("highlights while files hover and hands over the real paths on drop", async () => {
    (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__ = {};
    const onPaths = vi.fn();
    render(<Probe onPaths={onPaths} />);
    await vi.waitFor(() => expect(handler).not.toBeNull());
    act(() => handler!({ payload: { type: "enter", paths: ["C:\\a.png"] } }));
    expect(screen.getByTestId("state")).toHaveTextContent("dropping");
    act(() => handler!({ payload: { type: "leave" } }));
    expect(screen.getByTestId("state")).toHaveTextContent("idle");
    act(() => handler!({ payload: { type: "drop", paths: ["C:\\a.png", "C:\\b.txt"] } }));
    expect(onPaths).toHaveBeenCalledWith(["C:\\a.png", "C:\\b.txt"]);
    expect(screen.getByTestId("state")).toHaveTextContent("idle");
  });

  it("stops listening when it unmounts or is disabled", async () => {
    (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__ = {};
    const { unmount } = render(<Probe onPaths={() => {}} />);
    await vi.waitFor(() => expect(handler).not.toBeNull());
    unmount();
    await vi.waitFor(() => expect(unlisten).toHaveBeenCalled());
  });
});
