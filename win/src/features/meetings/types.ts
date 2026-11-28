export type Tone = "recording" | "working" | "ready" | "failed";
export type Badge = { label: string; tone: Tone };

export type Row = {
  id: string;
  title: string;
  date_text: string;
  duration_text: string;
  badge: Badge;
  detail: string | null;
  notice: string | null;
  has_note: boolean;
  has_transcript: boolean;
};

export type Line = {
  id: string;
  time: string;
  speaker: string;
  text: string;
  is_partial: boolean;
  is_mine: boolean;
  is_bookmark: boolean;
  is_pause: boolean;
};

export type Phase = "idle" | "starting" | "recording" | "finishing";
export type Sources = "both" | "mic" | "system";

export type AssistItem = { id: string; kind: string; label: string; text: string };
export type BrainHit = { path: string; title: string; snippet: string };
export type CheckItem = { id: string; text: string; done: boolean };
export type ChannelMetrics = { words: number; speaking_s: number; wpm: number; questions: number; longest_monologue_s: number };
export type Metrics = { duration_s: number; you: ChannelMetrics; others: ChannelMetrics; silence_s: number };

export type Copilot = {
  assist: boolean;
  lookup: boolean;
  lookup_others: boolean;
  nudges: boolean;
  items: AssistItem[];
  hits: BrainHit[];
  nudge: { kind: string; text: string } | null;
  metrics: Metrics | null;
  checklist: CheckItem[];
  prep: CheckItem[];
};

export type WebhookOffer = {
  id: string;
  host: string;
  masked_url: string;
  preview: string;
  size: string;
  signed: boolean;
  body: string;
  formatted: string;
};

export type JobInfo = { kind: string; stage: string | null; fraction: number | null };

export type MeetingsState = {
  phase: Phase;
  meeting: string | null;
  elapsed: number;
  paused: boolean;
  sources: Sources;
  source_labels: Record<Sources, string>;
  warnings: string[];
  levels: { mic: number; system: number };
  lag: boolean;
  saving: number | null;
  message: { text: string; tone: "info" | "error" } | null;
  live_model_ready: boolean;
  copilot: Copilot;
  processing: Record<string, JobInfo>;
  webhook_offers: Record<string, WebhookOffer>;
};

export type Detail = {
  row: Row;
  meta: {
    status: string | null;
    failure: string | null;
    notice: string | null;
    brain_error: string | null;
    started_at: string | null;
    duration_s: number | null;
    title: string | null;
    metrics: Metrics | null;
    language: string | null;
    note_state: string | null;
    sources: string | null;
    webhook_sent_at: string | null;
  };
  note: string | null;
  lines: Line[];
  has_audio: boolean;
  brain: { label: string; opens_note: boolean };
  job: JobInfo | null;
  webhook_offer: WebhookOffer | null;
};

export type ModelItem = {
  id: string;
  label: string;
  license: string;
  size_bytes: number;
  role: "live" | "refine";
  wanted: boolean;
  installed: boolean;
  downloading: boolean;
  progress: number | null;
  error: string | null;
};

export type SettingsValues = {
  webhookEnabled: boolean;
  webhookSigns: boolean;
  limitMinutes: number;
  autoSummary: boolean;
  language: string;
  postCallEngine: string;
  cleanupDays: number;
};

export type WebhookConfig = { url_set: boolean; masked_url: string | null; secret_set: boolean; enabled: boolean; signs: boolean };

export type SettingsPayload = {
  values: SettingsValues;
  languages: { id: string; label: string }[];
  engines: { id: string; label: string }[];
  limit_choices: number[];
  cleanup_choices: number[];
  recordings_path: string;
  webhook: WebhookConfig;
  brain_search: boolean;
};
