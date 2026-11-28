export type TextBlock = { type: "text"; text: string };
export type ToolUseBlock = { type: "tool_use"; id: string; name: string; input: unknown };
export type ToolResultBlock = {
  type: "tool_result";
  tool_use_id: string;
  content: unknown;
  is_error?: boolean;
};
export type Block = TextBlock | ToolUseBlock | ToolResultBlock;

export type Role = "user" | "assistant";
export type Message = { role: Role; blocks: Block[] };

export type ConversationSummary = {
  id: string;
  title: string;
  updated_at: string;
  engine: string;
  preview?: string | null;
  closed?: boolean;
};

export type Conversation = { id: string; title: string; messages: Message[]; closed?: boolean };

export type ThinkingState = "thinking" | "idle" | "error";

export type Usage = Record<string, unknown>;

export type RateWindow = { utilization: number; resets_at: number | null };
export type UsageWindows = { five_hour: RateWindow | null; seven_day: RateWindow | null };

export type PermissionCardFields = {
  summary?: string;
  detail?: string;
  summary_truncated?: boolean;
  requires_expansion?: boolean;
  can_persist?: boolean;
  persist_rules?: string[];
  persist_where?: string[];
  engine?: string;
  asker?: string;
};

export type StagedFile = { path: string; name: string; bytes: number; image: boolean };
export type StageResult = { files: StagedFile[]; refused: string[]; notice: string | null };

export type EngineId = "claude" | "codex" | "local";
export type EngineInfo = { id: EngineId; name: string; ready: boolean; note: string | null };
export type EngineOverview = { active: EngineId; engines: EngineInfo[] };

type Base = { conversation_id: string };

export type ServerEvent =
  | (Base & { type: "status"; state: ThinkingState })
  | (Base & { type: "text_delta"; text: string })
  | (Base & { type: "assistant_message"; message: Message })
  | (Base & { type: "tool_use"; id: string; name: string; input: unknown })
  | (Base & { type: "tool_result"; tool_use_id: string; content: unknown; is_error?: boolean })
  | (Base & ({ type: "permission_request"; request_id: string; tool_name: string; input: unknown } & PermissionCardFields))
  | (Base & { type: "result"; usage: Usage; text?: string; is_error?: boolean; session_id?: string; status?: string | null })
  | (Base & { type: "error"; message: string })
  | (Base & { type: "title"; title: string })
  | (Base & { type: "system"; text: string })
  | (Base & ({ type: "usage" } & UsageWindows));

export type SidecarInfo = { port: number; token: string };

export type FeatureEvent = { feature: string; type: string; [field: string]: unknown };
