import { useCallback, useEffect, useMemo, useReducer, useRef } from "react";
import { createClient } from "../api/client";
import { connectEvents } from "../api/events";
import type { SidecarInfo } from "../api/types";
import { chatReducer, initialChat } from "./chat";

export type ChatDeps = {
  fetchImpl?: typeof fetch;
  createSource?: (url: string) => EventSource;
};

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

export function useChat(info: SidecarInfo, deps: ChatDeps = {}) {
  const [state, dispatch] = useReducer(chatReducer, initialChat);
  const client = useMemo(() => createClient(info, deps.fetchImpl), [info, deps.fetchImpl]);
  const currentRef = useRef<string | null>(null);
  currentRef.current = state.currentId;

  const guard = useCallback(async (work: () => Promise<void>) => {
    try {
      await work();
    } catch (e) {
      dispatch({ type: "failed", message: message(e) });
    }
  }, []);

  const refreshList = useCallback(
    () => guard(async () => dispatch({ type: "list", items: await client.listConversations() })),
    [client, guard],
  );

  const open = useCallback(
    (id: string) => guard(async () => dispatch({ type: "opened", conversation: await client.getConversation(id) })),
    [client, guard],
  );

  useEffect(
    () =>
      connectEvents({
        info,
        createSource: deps.createSource,
        onEvent: (event) => {
          dispatch({ type: "event", event });
          if (event.type === "status" && event.state === "idle") {
            void refreshList();
            if (event.conversation_id === currentRef.current) void open(event.conversation_id);
          }
        },
        onOpen: () => {
          void refreshList();
          if (currentRef.current) void open(currentRef.current);
        },
      }),
    [info, deps.createSource, refreshList, open],
  );

  const send = useCallback(
    (text: string) =>
      guard(async () => {
        let id = currentRef.current;
        if (!id) {
          id = await client.createConversation();
          dispatch({ type: "opened", conversation: { id, title: "", messages: [] } });
        }
        dispatch({ type: "sent", text });
        await client.sendMessage(id, text);
        void refreshList();
      }),
    [client, guard, refreshList],
  );

  const stop = useCallback(
    () => guard(async () => void (currentRef.current && (await client.stop(currentRef.current)))),
    [client, guard],
  );

  const answer = useCallback(
    (requestId: string, allow: boolean, note?: string) =>
      guard(async () => {
        await client.answerPermission(requestId, allow, note);
        dispatch({ type: "permission-answered", requestId });
      }),
    [client, guard],
  );

  const newConversation = useCallback(() => dispatch({ type: "reset-current" }), []);

  return { state, open, send, stop, answer, newConversation };
}
