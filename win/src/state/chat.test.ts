import type { ServerEvent, StagedFile } from "../api/types";
import { chatReducer, initialChat, type ChatState } from "./chat";

const apply = (state: ChatState, event: ServerEvent) => chatReducer(state, { type: "event", event });
const file = (n: number): StagedFile => ({ path: `/a/${n}`, name: `${n}.txt`, bytes: n, image: false });
const open = (id: string): ChatState =>
  chatReducer(initialChat, { type: "opened", conversation: { id, title: id, messages: [] } });

describe("chat reducer: Mac parity", () => {
  it("keeps the card fields of a permission request, and only those the server sent", () => {
    const state = apply(open("c1"), {
      conversation_id: "c1", type: "permission_request", request_id: "r1", tool_name: "Bash", input: {},
      summary: "rodar ls", detail: "ls", requires_expansion: false, can_persist: true, persist_rules: ["Bash(ls *)"],
      persist_where: ["configurações locais do projeto"], asker: "Codex",
    });
    expect(state.permissions[0]).toMatchObject({
      requestId: "r1", summary: "rodar ls", requiresExpansion: false, canPersist: true, persistRules: ["Bash(ls *)"],
      persistWhere: ["configurações locais do projeto"], asker: "Codex",
    });
    const bare = apply(open("c1"), { conversation_id: "c1", type: "permission_request", request_id: "r2", tool_name: "Bash", input: {} });
    expect(bare.permissions[0]!.requiresExpansion).toBeUndefined();
  });

  it("a title event renames the list row, and the header only when it is the open conversation", () => {
    const listed = chatReducer(open("c1"), {
      type: "list",
      items: [
        { id: "c1", title: "a", updated_at: "x", engine: "claude" },
        { id: "c2", title: "b", updated_at: "x", engine: "claude" },
      ],
    });
    const other = apply(listed, { conversation_id: "c2", type: "title", title: "Novo B" });
    expect(other.title).toBe("c1");
    expect(other.conversations.map((c) => c.title)).toEqual(["a", "Novo B"]);
    expect(apply(other, { conversation_id: "c1", type: "title", title: "Novo A" }).title).toBe("Novo A");
  });

  it("keeps system notes per conversation, apart from the messages a refetch replaces", () => {
    const noted = apply(open("c1"), { conversation_id: "c1", type: "system", text: "nota" });
    const refetched = chatReducer(noted, { type: "opened", conversation: { id: "c1", title: "c1", messages: [] } });
    expect(refetched.notes).toEqual({ c1: ["nota"] });
  });

  it("marks an unseen reply only for another conversation and an error never counts", () => {
    const base = open("c1");
    const unseen = apply(base, { conversation_id: "c2", type: "result", usage: {}, is_error: false });
    expect(unseen.unseen).toEqual(["c2"]);
    expect(apply(unseen, { conversation_id: "c2", type: "result", usage: {} }).unseen).toEqual(["c2"]);
    expect(apply(base, { conversation_id: "c1", type: "result", usage: {} }).unseen).toEqual([]);
    expect(apply(base, { conversation_id: "c3", type: "result", usage: {}, is_error: true }).unseen).toEqual([]);
    expect(chatReducer(unseen, { type: "opened", conversation: { id: "c2", title: "", messages: [] } }).unseen).toEqual([]);
  });

  it("stores the usage windows", () => {
    const state = apply(initialChat, { conversation_id: "x", type: "usage", five_hour: { utilization: 0.5, resets_at: null }, seven_day: null });
    expect(state.usage).toEqual({ five_hour: { utilization: 0.5, resets_at: null }, seven_day: null });
  });

  it("pending attachments: dedupe, cap at ten, remove, and clear on send", () => {
    let state = chatReducer(initialChat, { type: "attached", files: [file(1), file(2)], notice: "aviso" });
    state = chatReducer(state, { type: "attached", files: [file(2), file(3)], notice: null });
    expect(state.pending.map((f) => f.bytes)).toEqual([1, 2, 3]);
    expect(state.attachNotice).toBeNull();
    state = chatReducer(state, { type: "attached", files: Array.from({ length: 12 }, (_, i) => file(10 + i)), notice: null });
    expect(state.pending).toHaveLength(10);
    state = chatReducer(state, { type: "detached", path: "/a/1" });
    expect(state.pending.some((f) => f.path === "/a/1")).toBe(false);
    state = chatReducer(state, { type: "attach-failed", message: "falhou" });
    expect(state.attachNotice).toBe("falhou");
    expect(chatReducer(state, { type: "sent", text: "oi" }).pending).toEqual([]);
  });

  it("removing the open conversation resets the screen, and rename/reopen touch the row", () => {
    let state = chatReducer(open("c1"), {
      type: "list",
      items: [{ id: "c1", title: "a", updated_at: "x", engine: "claude", closed: true }],
    });
    state = chatReducer(state, { type: "reopened", id: "c1" });
    expect(state.conversations[0]!.closed).toBe(false);
    state = chatReducer(state, { type: "renamed", id: "c1", title: "z" });
    expect(state.title).toBe("z");
    state = chatReducer(state, { type: "removed", id: "c1" });
    expect(state).toMatchObject({ currentId: null, conversations: [], messages: [] });
  });
});
