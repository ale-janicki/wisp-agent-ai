export type Machine = {
  name: string;
  cpu: string;
  os: string;
  build: string;
  cores: number;
  threads: number;
  boot_time: number;
};

export type Pressure = "normal" | "warning" | "critical";

export type Memory = {
  total: number;
  used: number;
  available: number;
  swap_total: number;
  swap_used: number;
  used_fraction: number;
  pressure: Pressure;
};

export type Volume = { id: string; name: string; total: number; available: number; is_boot: boolean };
export type BatteryState = "charging" | "charged" | "on_ac" | "discharging";
export type Battery = { percent: number; state: BatteryState; minutes_to_empty: number | null };
export type ProcessRow = { pid: number; name: string; cpu: number; rss: number };

export type Sample = {
  cpu: { total: number } | null;
  memory: Memory | null;
  network: { interface: string; address: string | null; rate: { down: number; up: number } | null } | null;
  volumes: Volume[];
  temperature: { average: number; max: number } | null;
  battery: Battery | null;
  top_cpu: ProcessRow[] | null;
  top_memory: ProcessRow[] | null;
};
