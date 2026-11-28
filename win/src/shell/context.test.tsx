import { act, render, screen, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { useState } from "react";
import { createFeatureBus } from "../api/featureEvents";
import { fakeFetch } from "../test/fakes";
import { ShellContext, useFeatureApi, useFeatureEvents, type ShellValue } from "./context";

const info = { port: 4242, token: "tok" };

function Probe() {
  const api = useFeatureApi("tasks");
  const [seen, setSeen] = useState<string[]>([]);
  const [items, setItems] = useState("-");
  useFeatureEvents("tasks", (e) => setSeen((s) => [...s, String(e.type)]));
  return (
    <>
      <button onClick={() => void api.get<{ n: number }>("/count").then((r) => setItems(String(r.n)))}>load</button>
      <output aria-label="items">{items}</output>
      <output aria-label="seen">{seen.join(",")}</output>
    </>
  );
}

const wrap = (value: Partial<ShellValue>, children: ReactNode) => (
  <ShellContext.Provider value={{ info, session: null as never, draft: "", setDraft: () => {}, focusComposer: false, navigate: () => {}, bus: createFeatureBus(), ...value }}>
    {children}
  </ShellContext.Provider>
);

describe("feature hooks", () => {
  it("useFeatureApi hits /api/<feature>/… with the token", async () => {
    const { impl, calls } = fakeFetch({ "GET /api/tasks/count": () => ({ n: 3 }) });
    render(wrap({ fetchImpl: impl }, <Probe />));
    act(() => screen.getByText("load").click());
    await waitFor(() => expect(screen.getByLabelText("items")).toHaveTextContent("3"));
    expect(calls[0]).toMatchObject({ method: "GET", path: "/api/tasks/count", auth: "Bearer tok" });
  });

  it("useFeatureEvents gets only its own feature's events", () => {
    const bus = createFeatureBus();
    render(wrap({ bus }, <Probe />));
    act(() => {
      bus.emit({ feature: "tasks", type: "changed" });
      bus.emit({ feature: "agenda", type: "other" });
    });
    expect(screen.getByLabelText("seen")).toHaveTextContent("changed");
    expect(screen.getByLabelText("seen")).not.toHaveTextContent("other");
  });
});
