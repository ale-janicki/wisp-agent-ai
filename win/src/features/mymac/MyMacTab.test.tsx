import { act, screen, waitFor } from "@testing-library/react";
import { afterEach, vi } from "vitest";
import { fakeFetch } from "../../test/fakes";
import { mountInShell } from "../home/testShell";
import { MyMacTab } from "./MyMacTab";
import type { Machine, Sample } from "./types";

const machine: Machine = {
  name: "PC-DA-MARIA",
  cpu: "Ryzen 7 5800X",
  os: "Windows 11",
  build: "10.0.22631",
  cores: 8,
  threads: 16,
  boot_time: Date.now() / 1000 - 3 * 3600 - 7 * 60,
};

const sample = (over: Partial<Sample> = {}): Sample => ({
  cpu: { total: 0.456 },
  memory: { total: 16 * 1024 ** 3, used: 6 * 1024 ** 3, available: 10 * 1024 ** 3, swap_total: 2 * 1024 ** 3, swap_used: 0, used_fraction: 0.375, pressure: "normal" },
  network: { interface: "Wi-Fi", address: "192.168.0.7", rate: { down: 2_500_000, up: 120_000 } },
  volumes: [
    { id: "C:\\", name: "C:\\", total: 500_000_000_000, available: 200_000_000_000, is_boot: true },
    { id: "D:\\", name: "D:\\", total: 1_000_000_000_000, available: 900_000_000_000, is_boot: false },
  ],
  temperature: null,
  battery: { percent: 80, state: "discharging", minutes_to_empty: 135 },
  top_cpu: [{ pid: 7, name: "chrome.exe", cpu: 31.4, rss: 800_000_000 }],
  top_memory: [{ pid: 9, name: "code.exe", cpu: 2, rss: 1_500_000_000 }],
  ...over,
});

afterEach(() => vi.useRealTimers());

function mount(next: () => Sample) {
  const { impl, calls } = fakeFetch({ "GET /api/mymac/machine": () => machine, "GET /api/mymac/sample": () => next() });
  mountInShell(<MyMacTab />, { fetchImpl: impl });
  return calls;
}

describe("My Mac tab on Windows", () => {
  it("names the machine and shows how long it has been on", async () => {
    mount(() => sample());
    expect(await screen.findByRole("heading", { name: "PC-DA-MARIA" })).toBeInTheDocument();
    expect(screen.getByText(/Ryzen 7 5800X · Windows 11 \(10\.0\.22631\) · ligado há 3 h 07 min/)).toBeInTheDocument();
  });

  it("draws CPU, memory, network and disk from the sidecar's sample", async () => {
    mount(() => sample());
    expect(await screen.findByText("46%")).toBeInTheDocument();
    expect(screen.getByText("8 núcleos · 16 threads")).toBeInTheDocument();
    expect(screen.getByText("6 GB")).toBeInTheDocument();
    expect(screen.getByText("de 16 GB")).toBeInTheDocument();
    expect(screen.getByText("Pressão normal")).toBeInTheDocument();
    expect(screen.getByText("↓ 2,5 MB/s")).toBeInTheDocument();
    expect(screen.getByText("IP 192.168.0.7")).toBeInTheDocument();
    expect(screen.getByText("200 GB")).toBeInTheDocument();
    expect(screen.getByText("livres de 500 GB")).toBeInTheDocument();
    expect(screen.getByText("D:\\ · 900 GB livres de 1 TB")).toBeInTheDocument();
  });

  it("says temperature sensors are unavailable instead of inventing a reading", async () => {
    mount(() => sample());
    expect(await screen.findByText("Sensores de temperatura indisponíveis")).toBeInTheDocument();
  });

  it("shows the battery, then drops the tile on a desktop without one", async () => {
    mount(() => sample());
    expect(await screen.findByText("80%")).toBeInTheDocument();
    expect(screen.getByText("2 h 15 min restantes")).toBeInTheDocument();
    expect(screen.getByText("Na bateria")).toBeInTheDocument();
  });

  it("hides the battery tile when there is none", async () => {
    mount(() => sample({ battery: null }));
    await screen.findByText("46%");
    expect(screen.queryByRole("region", { name: "Bateria" })).not.toBeInTheDocument();
  });

  it("lists the heaviest processes and says so when they cannot be read", async () => {
    mount(() => sample());
    expect(await screen.findByText("chrome.exe")).toBeInTheDocument();
    expect(screen.getByText("31,4%")).toBeInTheDocument();
    expect(screen.getByText("1,4 GB")).toBeInTheDocument();
  });

  it("reports unreadable processes and a missing network the Mac's way", async () => {
    mount(() => sample({ top_cpu: null, top_memory: null, network: null }));
    expect(await screen.findAllByText("Não consegui listar os processos")).toHaveLength(2);
    expect(screen.getByText("Sem conexão de rede")).toBeInTheDocument();
  });

  it("samples at once, again after a second, then every two seconds, and stops on close", async () => {
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "setTimeout", "clearTimeout"] });
    let n = 0;
    const { impl, calls } = fakeFetch({ "GET /api/mymac/machine": () => machine, "GET /api/mymac/sample": () => sample({ cpu: { total: ++n / 100 } }) });
    const view = mountInShell(<MyMacTab />, { fetchImpl: impl });
    const advance = (ms: number) =>
      act(async () => {
        await vi.advanceTimersByTimeAsync(ms);
      });
    await advance(0);
    expect(screen.getByText("1%")).toBeInTheDocument();
    await advance(1000);
    expect(screen.getByText("2%")).toBeInTheDocument();
    await advance(1999);
    expect(screen.getByText("2%")).toBeInTheDocument();
    await advance(1);
    expect(screen.getByText("3%")).toBeInTheDocument();
    view.unmount();
    await advance(10_000);
    expect(calls.filter((c) => c.path.endsWith("/sample"))).toHaveLength(3);
  });

  it("explains when the sidecar cannot read the machine", async () => {
    const { impl } = fakeFetch({});
    mountInShell(<MyMacTab />, { fetchImpl: impl });
    await waitFor(() => expect(screen.getByText("Não consegui ler o sistema")).toBeInTheDocument());
  });
});
