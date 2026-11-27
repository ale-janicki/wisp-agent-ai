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
};

export type Conversation = { id: string; title: string; messages: Message[] };

export type ThinkingState = "thinking" | "idle" | "error";

export type Usage = Record<string, unknown>;

type Base = { conversation_id: string };

export type ServerEvent =
  | (Base & { type: "status"; state: ThinkingState })
  | (Base & { type: "text_delta"; text: string })
  | (Base & { type: "assistant_message"; message: Message })
  | (Base & { type: "tool_use"; id: string; name: string; input: unknown })
  | (Base & { type: "tool_result"; tool_use_id: string; content: unknown; is_error?: boolean })
  | (Base & { type: "permission_request"; request_id: string; tool_name: string; input: unknown })
  | (Base & { type: "result"; usage: Usage })
  | (Base & { type: "error"; message: string });

export type SidecarInfo = { port: number; token: string };
