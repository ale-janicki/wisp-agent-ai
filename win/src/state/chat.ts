import type {
  Block,
  Conversation,
  ConversationSummary,
  Message,
  ServerEvent,
  ThinkingState,
  ToolResultBlock,
  ToolUseBlock,
} from "../api/types";

export type PendingPermission = {
  requestId: string;
  conversationId: string;
  toolName: string;
  input: unknown;
};

export type ChatState = {
  conversations: ConversationSummary[];
  currentId: string | null;
  title: string;
  messages: Message[];
  streaming: string;
  liveTools: Block[];
  status: Record<string, ThinkingState>;
  permissions: PendingPermission[];
  error: string | null;
};

export const initialChat: ChatState = {
  conversations: [],
  currentId: null,
  title: "",
  messages: [],
  streaming: "",
  liveTools: [],
  status: {},
  permissions: [],
  error: null,
};

export type ChatAction =
  | { type: "list"; items: ConversationSummary[] }
  | { type: "opened"; conversation: Conversation }
  | { type: "reset-current" }
  | { type: "sent"; text: string }
  | { type: "failed"; message: string }
  | { type: "permission-answered"; requestId: string }
  | { type: "event"; event: ServerEvent };

export function chatReducer(state: ChatState, action: ChatAction): ChatState {
  switch (action.type) {
    case "list":
      return { ...state, conversations: action.items };
    case "opened":
      return {
        ...state,
        currentId: action.conversation.id,
        title: action.conversation.title,
        messages: action.conversation.messages,
        streaming: "",
        liveTools: [],
        error: null,
      };
    case "reset-current":
      return { ...state, currentId: null, title: "", messages: [], streaming: "", liveTools: [], error: null };
    case "sent":
      return {
        ...state,
        error: null,
        messages: [...state.messages, { role: "user", blocks: [{ type: "text", text: action.text }] }],
      };
    case "failed":
      return { ...state, error: action.message };
    case "permission-answered":
      return { ...state, permissions: state.permissions.filter((p) => p.requestId !== action.requestId) };
    case "event":
      return applyEvent(state, action.event);
  }
}

function applyEvent(state: ChatState, event: ServerEvent): ChatState {
  const current = event.conversation_id === state.currentId;
  switch (event.type) {
    case "status":
      return {
        ...state,
        status: { ...state.status, [event.conversation_id]: event.state },
        streaming: current && event.state === "idle" ? "" : state.streaming,
      };
    case "text_delta":
      return current ? { ...state, streaming: state.streaming + event.text } : state;
    case "assistant_message":
      return current ? { ...state, streaming: "", messages: [...state.messages, event.message] } : state;
    case "tool_use":
      if (!current) return state;
      return { ...state, liveTools: [...state.liveTools, { type: "tool_use", id: event.id, name: event.name, input: event.input }] };
    case "tool_result":
      if (!current) return state;
      return {
        ...state,
        liveTools: [
          ...state.liveTools,
          { type: "tool_result", tool_use_id: event.tool_use_id, content: event.content, is_error: event.is_error },
        ],
      };
    case "permission_request":
      if (state.permissions.some((p) => p.requestId === event.request_id)) return state;
      return {
        ...state,
        permissions: [
          ...state.permissions,
          { requestId: event.request_id, conversationId: event.conversation_id, toolName: event.tool_name, input: event.input },
        ],
      };
    case "error":
      return { ...state, error: event.message, status: { ...state.status, [event.conversation_id]: "error" } };
    case "result":
      return state;
  }
}

export type ToolEntry = { use: ToolUseBlock; result?: ToolResultBlock };

export function collectTools(messages: Message[], live: Block[]): Map<string, ToolEntry> {
  const map = new Map<string, ToolEntry>();
  const blocks = [...messages.flatMap((m) => m.blocks), ...live];
  for (const b of blocks) if (b.type === "tool_use" && !map.has(b.id)) map.set(b.id, { use: b });
  for (const b of blocks) {
    if (b.type !== "tool_result") continue;
    const entry = map.get(b.tool_use_id);
    if (entry) entry.result = b;
  }
  return map;
}

export function liveOnlyTools(messages: Message[], live: Block[]): ToolUseBlock[] {
  const persisted = new Set(
    messages.flatMap((m) => m.blocks).flatMap((b) => (b.type === "tool_use" ? [b.id] : [])),
  );
  const seen = new Set<string>();
  const out: ToolUseBlock[] = [];
  for (const b of live) {
    if (b.type !== "tool_use" || persisted.has(b.id) || seen.has(b.id)) continue;
    seen.add(b.id);
    out.push(b);
  }
  return out;
}
