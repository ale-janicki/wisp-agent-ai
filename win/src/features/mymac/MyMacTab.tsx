import { useEffect, useState, type ReactNode } from "react";
import { useFeatureApi } from "../../shell/context";
import { bytes, celsius, duration, percent, processCpu, rate } from "./format";
import type { Battery, Machine, Memory, ProcessRow, Sample, Volume } from "./types";
import styles from "./MyMacTab.module.css";

const HISTORY = 30;
const FIRST_DELAY = 1000;
const INTERVAL = 2000;
const NETWORK_FLOOR = 50_000;

const push = (series: number[], value: number) => [...series, Number.isFinite(value) ? value : 0].slice(-HISTORY);

type Histories = { cpu: number[]; memory: number[]; down: number[]; up: number[] };
const EMPTY: Histories = { cpu: [], memory: [], down: [], up: [] };

export function MyMacTab() {
  const api = useFeatureApi("mymac");
  const [machine, setMachine] = useState<Machine | null>(null);
  const [sample, setSample] = useState<Sample | null>(null);
  const [failed, setFailed] = useState(false);
  const [history, setHistory] = useState<Histories>(EMPTY);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    let alive = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const run = async (first: boolean) => {
      try {
        const next = await api.get<Sample>("/sample");
        if (!alive) return;
        setSample(next);
        setFailed(false);
        setNow(Date.now());
        setHistory((h) => ({
          cpu: next.cpu ? push(h.cpu, next.cpu.total) : h.cpu,
          memory: next.memory ? push(h.memory, next.memory.used_fraction) : h.memory,
          down: next.network?.rate ? push(h.down, next.network.rate.down) : h.down,
          up: next.network?.rate ? push(h.up, next.network.rate.up) : h.up,
        }));
      } catch {
        if (alive) setFailed(true);
      }
      if (alive) timer = setTimeout(() => void run(false), first ? FIRST_DELAY : INTERVAL);
    };
    api
      .get<Machine>("/machine")
      .then((m) => alive && setMachine(m))
      .catch(() => alive && setFailed(true));
    void run(true);
    return () => {
      alive = false;
      clearTimeout(timer);
    };
  }, [api]);

  if (failed && !sample) {
    return (
      <div className={styles.tab}>
        <p className={styles.message}>Não consegui ler o sistema</p>
      </div>
    );
  }

  return (
    <div className={styles.tab}>
      <Header machine={machine} now={now} />
      <div className={styles.row}>
        <CpuTile sample={sample} machine={machine} series={history.cpu} />
        <MemoryTile sample={sample} series={history.memory} />
        <NetworkTile sample={sample} down={history.down} up={history.up} />
      </div>
      <div className={styles.row}>
        <DiskTile sample={sample} />
        <TemperatureTile sample={sample} />
        {(sample === null || sample.battery !== null) && <BatteryTile battery={sample?.battery ?? null} />}
      </div>
      <div className={styles.row}>
        <ProcessTile title="Mais CPU" rows={sample ? sample.top_cpu : undefined} value={(p) => processCpu(p.cpu)} />
        <ProcessTile title="Mais memória" rows={sample ? sample.top_memory : undefined} value={(p) => bytes(p.rss, true)} />
      </div>
    </div>
  );
}

function Header({ machine, now }: { machine: Machine | null; now: number }) {
  if (!machine) return <div className={styles.head} aria-busy />;
  const parts = [
    machine.cpu,
    machine.build ? `${machine.os} (${machine.build})` : machine.os,
    `ligado há ${duration(now / 1000 - machine.boot_time)}`,
  ].filter(Boolean);
  return (
    <div className={styles.head}>
      <h2 className={styles.name}>{machine.name}</h2>
      <div className={styles.subtitle}>{parts.join(" · ")}</div>
    </div>
  );
}

function Tile({ title, trailing, dot, children }: { title: string; trailing?: string; dot?: "ok" | "warning" | "critical"; children: ReactNode }) {
  return (
    <section className={styles.tile} aria-label={title}>
      <header className={styles.tileHead}>
        <h3 className={styles.tileTitle}>{title}</h3>
        {trailing && (
          <span className={styles.trailing}>
            {dot && <span className={`${styles.dot} ${styles[dot]}`} aria-hidden />}
            {trailing}
          </span>
        )}
      </header>
      {children}
    </section>
  );
}

function Figure({ value, detail }: { value: string; detail?: string }) {
  return (
    <div className={styles.figure}>
      <span className={styles.value}>{value}</span>
      {detail && <span className={styles.figureDetail}>{detail}</span>}
    </div>
  );
}

const Detail = ({ text }: { text: string }) => <div className={styles.detail}>{text}</div>;
const Loading = () => <div className={styles.skeleton} aria-busy />;

function Sparkline({ series, colors = ["var(--accent)"] }: { series: number[][]; colors?: string[] }) {
  return (
    <svg className={styles.spark} viewBox="0 0 100 36" preserveAspectRatio="none" aria-hidden>
      {series.map((values, i) =>
        values.length > 1 ? (
          <polyline
            key={i}
            fill="none"
            stroke={colors[i % colors.length]}
            strokeWidth={1.5}
            vectorEffect="non-scaling-stroke"
            points={values.map((v, k) => `${(100 * k) / (values.length - 1)},${1 + 34 * (1 - Math.min(1, Math.max(0, v)))}`).join(" ")}
          />
        ) : null,
      )}
    </svg>
  );
}

const normalize = (values: number[], floor = 0) => {
  const peak = Math.max(floor, ...values, 0);
  return peak > 0 ? values.map((v) => v / peak) : values.map(() => 0);
};

function CpuTile({ sample, machine, series }: { sample: Sample | null; machine: Machine | null; series: number[] }) {
  const cpu = sample?.cpu;
  return (
    <Tile title="CPU">
      {cpu ? (
        <>
          <Figure value={percent(cpu.total)} detail="em uso" />
          {machine && <Detail text={`${machine.cores} núcleos · ${machine.threads} threads`} />}
          <Sparkline series={[normalize(series, 1)]} />
        </>
      ) : (
        <Loading />
      )}
    </Tile>
  );
}

const PRESSURE: Record<Memory["pressure"], string> = { normal: "normal", warning: "aviso", critical: "crítica" };

function MemoryTile({ sample, series }: { sample: Sample | null; series: number[] }) {
  const memory = sample?.memory;
  const dot = memory ? (memory.pressure === "normal" ? "ok" : memory.pressure === "warning" ? "warning" : "critical") : undefined;
  const color = memory?.pressure === "critical" ? "var(--error)" : memory?.pressure === "warning" ? "var(--busy)" : "var(--accent)";
  return (
    <Tile title="Memória" trailing={memory ? `Pressão ${PRESSURE[memory.pressure]}` : undefined} dot={dot}>
      {memory ? (
        <>
          <Figure value={bytes(memory.used, true)} detail={`de ${bytes(memory.total, true)}`} />
          <Detail text={`Disponível ${bytes(memory.available, true)}`} />
          <Detail text={memory.swap_total > 0 ? `Arquivo de paginação ${bytes(memory.swap_used, true)} de ${bytes(memory.swap_total, true)}` : "Sem arquivo de paginação"} />
          <Sparkline series={[series]} colors={[color]} />
        </>
      ) : (
        <Loading />
      )}
    </Tile>
  );
}

function NetworkTile({ sample, down, up }: { sample: Sample | null; down: number[]; up: number[] }) {
  const network = sample?.network;
  const peak = Math.max(NETWORK_FLOOR, ...down, ...up);
  return (
    <Tile title="Rede" trailing={network?.interface}>
      {sample && !network ? (
        <p className={styles.message}>Sem conexão de rede</p>
      ) : network?.rate ? (
        <>
          <div className={styles.rateLine}>↓ {rate(network.rate.down)}</div>
          <div className={styles.rateLine}>↑ {rate(network.rate.up)}</div>
          <Detail text={network.address ? `IP ${network.address}` : "Sem endereço IPv4"} />
          <Sparkline series={[down.map((v) => v / peak), up.map((v) => v / peak)]} colors={["var(--accent)", "#5cc9d6"]} />
        </>
      ) : (
        <Loading />
      )}
    </Tile>
  );
}

function DiskTile({ sample }: { sample: Sample | null }) {
  const volumes: Volume[] = sample?.volumes ?? [];
  const boot = volumes.find((v) => v.is_boot) ?? volumes[0];
  const fraction = boot && boot.total > 0 ? 1 - boot.available / boot.total : 0;
  return (
    <Tile title="Disco" trailing={boot?.name}>
      {boot ? (
        <>
          <Figure value={bytes(boot.available)} detail={`livres de ${bytes(boot.total)}`} />
          <div className={styles.bar}>
            <div className={`${styles.barFill} ${fraction >= 0.9 ? styles.barFull : ""}`} style={{ width: `${Math.min(100, fraction * 100)}%` }} />
          </div>
          {volumes
            .filter((v) => v.id !== boot.id)
            .map((v) => (
              <Detail key={v.id} text={`${v.name} · ${bytes(v.available)} livres de ${bytes(v.total)}`} />
            ))}
        </>
      ) : sample ? (
        <p className={styles.message}>Não consegui ler o disco</p>
      ) : (
        <Loading />
      )}
    </Tile>
  );
}

function TemperatureTile({ sample }: { sample: Sample | null }) {
  const temperature = sample?.temperature;
  return (
    <Tile title="Temperatura">
      {!sample ? (
        <Loading />
      ) : temperature ? (
        <>
          <Figure value={celsius(temperature.average)} detail="sensores, média" />
          <Detail text={`máx ${celsius(temperature.max)}`} />
        </>
      ) : (
        <Detail text="Sensores de temperatura indisponíveis" />
      )}
    </Tile>
  );
}

const BATTERY_LABEL: Record<Battery["state"], string> = {
  charging: "Carregando",
  charged: "Carregada",
  on_ac: "Na tomada",
  discharging: "Na bateria",
};

function BatteryTile({ battery }: { battery: Battery | null }) {
  return (
    <Tile title="Bateria" trailing={battery ? BATTERY_LABEL[battery.state] : undefined}>
      {battery ? (
        <Figure
          value={`${battery.percent}%`}
          detail={
            battery.state === "discharging" && battery.minutes_to_empty !== null
              ? `${duration(battery.minutes_to_empty * 60)} restantes`
              : BATTERY_LABEL[battery.state].toLowerCase()
          }
        />
      ) : (
        <Loading />
      )}
    </Tile>
  );
}

function ProcessTile({ title, rows, value }: { title: string; rows: ProcessRow[] | null | undefined; value: (p: ProcessRow) => string }) {
  return (
    <Tile title={title}>
      {rows && rows.length > 0 ? (
        <div className={styles.processes}>
          {rows.map((p) => (
            <div key={p.pid} className={styles.process} title={`${p.name} · PID ${p.pid}`}>
              <span className={styles.processName}>{p.name}</span>
              <span>{value(p)}</span>
            </div>
          ))}
        </div>
      ) : rows !== undefined ? (
        <p className={styles.message}>Não consegui listar os processos</p>
      ) : (
        <Loading />
      )}
    </Tile>
  );
}
