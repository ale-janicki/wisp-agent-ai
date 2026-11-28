export type Detail = { command: string; exit: number; output: string };
export type Report = {
  step: string;
  status: "done" | "skipped" | "needs_user" | "failed";
  summary: string;
  details: Detail[];
  data: Record<string, string>;
};

export type EngineId = "claude" | "codex" | "local";
export type PermissionChoice = "default" | "auto" | "bypassPermissions";
export type PermissionSource = "profile" | "wisp" | "claude" | "standard";

export type SettingsState = {
  version: string;
  platform: string;
  engine: EngineId;
  permission: { choice: PermissionChoice | null; source: PermissionSource; claude_mode: string | null; profile_is_link: boolean };
  paths: { wisp_dir: string; has_wisp_dir: boolean; brain: string | null; brain_default: string; brain_missing: boolean; brain_learn: boolean };
  profile: { name: string; user: string; avatar: string | null };
  notices: Record<NoticeKey, boolean>;
  blocks: { routines: boolean; hooks: boolean; commands: boolean };
  setup_finished: boolean;
};

export type NoticeKey = "doNotDisturb" | "reply" | "telegram" | "reminder" | "update" | "approval" | "meeting" | "invite";

export type DoctorCheck = { id: string; ok: boolean; summary: string; step: string | null; data: Record<string, string> };
export type DoctorReport = { checks: DoctorCheck[] };

export type Lesson = { number: number; rule: string; date: string | null; origin: string | null; learned_alone: boolean };

export type RoutineRow = {
  label: string;
  name: string;
  description: string | null;
  summary: string;
  state: "running" | "waiting" | "unloaded" | "failed" | "missing";
  installed: boolean;
  logs: string[];
  always_on: boolean;
};
export type HookRow = { id: string; event: string; title: string; detail: string | null; command: string; enabled: boolean; locked: boolean; missing: boolean };
export type HookGroup = { event: string; title: string; hooks: HookRow[] };
export type McpServer = { name: string; scope: string; transport: string; installed_by_wisp: boolean; disabled: boolean };
export type CliTool = { name: string; directory: string; version: string | null; auth: string | null };

export type UpdateInfo = { version: string; tag: string; notes_url: string | null; asset: string | null; size: number | null; verified: boolean };

export type LoginState = "enabled" | "disabled" | "turned_off_by_user" | "other_copy";
export type LoginStatus = { state: LoginState; error: string | null };
