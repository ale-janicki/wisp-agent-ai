import type {
  Block,
  Conversation,
  ConversationSummary,
  EngineOverview,
  Message,
  ServerEvent,
  StagedFile,
  ThinkingState,
  ToolResultBlock,
  ToolUseBlock,
  UsageWindows,
} from "../api/types";

export type PendingPermission = {
  requestId: string;
  conversationId: string;
  toolName: string;
  input: unknown;
  summary?: string;
  detail?: string;
  summaryTruncated?: boolean;
  requiresExpansion?: boolean;
  canPersist?: boolean;
  persistRules?: string[];
  persistWhere?: string[];
  asker?: string;
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
  closed: boolean;
  notes: Record<string, string[]>;
  unseen: string[];
  usage: UsageWindows | null;
  engines: EngineOverview | null;
  pending: StagedFile[];
  attachNotice: string | null;
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
  closed: false,
  notes: {},
  unseen: [],
  usage: null,
  engines: null,
  pending: [],
  attachNotice: null,
};

export type ChatAction =
  | { type: "list"; items: ConversationSummary[] }
  | { type: "opened"; conversation: Conversation }
  | { type: "reset-current" }
  | { type: "sent"; text: string }
  | { type: "failed"; message: string }
  | { type: "permission-answered"; requestId: string }
  | { type: "renamed"; id: string; title: string }
  | { type: "removed"; id: string }
  | { type: "reopened"; id: string }
  | { type: "engines"; engines: EngineOverview }
  | { type: "usage"; usage: UsageWindows }
  | { type: "attached"; files: StagedFile[]; notice: string | null }
  | { type: "detached"; path: string }
  | { type: "attach-failed"; message: string }
  | { type: "event"; event: ServerEvent };

export const ATTACHMENT_LIMIT = 10;

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
        closed: action.conversation.closed === true,
        unseen: state.unseen.filter((id) => id !== action.conversation.id),
        streaming: "",
        liveTools: [],
        error: null,
      };
    case "reset-current":
      return { ...state, currentId: null, title: "", messages: [], streaming: "", liveTools: [], error: null, closed: false };
    case "sent":
      return {
        ...state,
        error: null,
        pending: [],
        attachNotice: null,
        messages: [...state.messages, { role: "user", blocks: [{ type: "text", text: action.text }] }],
      };
    case "renamed":
      return {
        ...state,
        title: action.id === state.currentId ? action.title : state.title,
        conversations: state.conversations.map((c) => (c.id === action.id ? { ...c, title: action.title } : c)),
      };
    case "removed":
      return {
        ...state,
        conversations: state.conversations.filter((c) => c.id !== action.id),
        permissions: state.permissions.filter((p) => p.conversationId !== action.id),
        unseen: state.unseen.filter((id) => id !== action.id),
        ...(action.id === state.currentId
          ? { currentId: null, title: "", messages: [], streaming: "", liveTools: [], error: null, closed: false }
          : {}),
      };
    case "reopened":
      return {
        ...state,
        closed: action.id === state.currentId ? false : state.closed,
        conversations: state.conversations.map((c) => (c.id === action.id ? { ...c, closed: false } : c)),
      };
    case "engines":
      return { ...state, engines: action.engines };
    case "usage":
      return { ...state, usage: action.usage };
    case "attached": {
      const known = new Set(state.pending.map((f) => f.path));
      const merged = [...state.pending, ...action.files.filter((f) => !known.has(f.path))].slice(0, ATTACHMENT_LIMIT);
      return { ...state, pending: merged, attachNotice: action.notice };
    }
    case "detached":
      return { ...state, pending: state.pending.filter((f) => f.path !== action.path), attachNotice: null };
    case "attach-failed":
      return { ...state, attachNotice: action.message };
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
          {
            requestId: event.request_id,
            conversationId: event.conversation_id,
            toolName: event.tool_name,
            input: event.input,
            summary: event.summary,
            detail: event.detail,
            summaryTruncated: event.summary_truncated,
            requiresExpansion: event.requires_expansion,
            canPersist: event.can_persist,
            persistRules: event.persist_rules,
            persistWhere: event.persist_where,
            asker: event.asker,
          },
        ],
      };
    case "error":
      return { ...state, error: event.message, status: { ...state.status, [event.conversation_id]: "error" } };
    case "result":
      return event.is_error || current || state.unseen.includes(event.conversation_id)
        ? state
        : { ...state, unseen: [...state.unseen, event.conversation_id] };
    case "title":
      return {
        ...state,
        title: current ? event.title : state.title,
        conversations: state.conversations.map((c) => (c.id === event.conversation_id ? { ...c, title: event.title } : c)),
      };
    case "system":
      return { ...state, notes: { ...state.notes, [event.conversation_id]: [...(state.notes[event.conversation_id] ?? []), event.text] } };
    case "usage":
      return { ...state, usage: { five_hour: event.five_hour, seven_day: event.seven_day } };
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
