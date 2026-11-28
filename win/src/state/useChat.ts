import { useCallback, useEffect, useMemo, useReducer, useRef } from "react";
import { createClient } from "../api/client";
import { connectEvents } from "../api/events";
import type { EngineId, FeatureEvent, SidecarInfo } from "../api/types";
import { composeAttachments } from "./attachments";
import { ATTACHMENT_LIMIT, chatReducer, initialChat } from "./chat";

export type ChatDeps = {
  fetchImpl?: typeof fetch;
  createSource?: (url: string) => EventSource;
  onFeatureEvent?: (event: FeatureEvent) => void;
};

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));
const refusedAll = "Não consegui preparar o anexo";

export function useChat(info: SidecarInfo, deps: ChatDeps = {}) {
  const [state, dispatch] = useReducer(chatReducer, initialChat);
  const client = useMemo(() => createClient(info, deps.fetchImpl), [info, deps.fetchImpl]);
  const currentRef = useRef<string | null>(null);
  currentRef.current = state.currentId;
  const pendingRef = useRef(state.pending);
  pendingRef.current = state.pending;
  const images = useRef(new Map<string, Promise<string>>());

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

  const refreshUsage = useCallback(
    () => client.usage().then((usage) => dispatch({ type: "usage", usage }), () => undefined),
    [client],
  );

  useEffect(
    () =>
      connectEvents({
        info,
        createSource: deps.createSource,
        onFeatureEvent: deps.onFeatureEvent,
        onEvent: (event) => {
          dispatch({ type: "event", event });
          if (event.type === "status" && event.state === "idle") {
            void refreshList();
            if (event.conversation_id === currentRef.current) void open(event.conversation_id);
          }
        },
        onOpen: () => {
          void refreshList();
          void refreshUsage();
          if (currentRef.current) void open(currentRef.current);
        },
      }),
    [info, deps.createSource, deps.onFeatureEvent, refreshList, refreshUsage, open],
  );

  const send = useCallback(
    (text: string) =>
      guard(async () => {
        const files = pendingRef.current;
        if (!text.trim() && files.length === 0) return;
        let id = currentRef.current;
        if (!id) {
          id = await client.createConversation();
          dispatch({ type: "opened", conversation: { id, title: "", messages: [] } });
        }
        dispatch({ type: "sent", text: files.length > 0 ? composeAttachments(files, text) : text });
        try {
          await client.sendMessage(id, text, files.map((f) => f.path));
        } catch (e) {
          if (files.length > 0) dispatch({ type: "attached", files, notice: null });
          throw e;
        }
        void refreshList();
      }),
    [client, guard, refreshList],
  );

  const stop = useCallback(
    () => guard(async () => void (currentRef.current && (await client.stop(currentRef.current)))),
    [client, guard],
  );

  const answer = useCallback(
    (requestId: string, allow: boolean, note?: string, always?: boolean) =>
      guard(async () => {
        await client.answerPermission(requestId, allow, note, always);
        dispatch({ type: "permission-answered", requestId });
      }),
    [client, guard],
  );

  const rename = useCallback(
    (id: string, title: string) =>
      guard(async () => {
        const done = await client.renameConversation(id, title);
        dispatch({ type: "renamed", id, title: done.title });
      }),
    [client, guard],
  );

  const remove = useCallback(
    (id: string) =>
      guard(async () => {
        await client.deleteConversation(id);
        dispatch({ type: "removed", id });
      }),
    [client, guard],
  );

  const reopen = useCallback(
    (id: string) =>
      guard(async () => {
        await client.reopenConversation(id);
        dispatch({ type: "reopened", id });
      }),
    [client, guard],
  );

  const room = () => ATTACHMENT_LIMIT - pendingRef.current.length;

  const attachPaths = useCallback(
    (paths: string[]) =>
      guard(async () => {
        const take = paths.slice(0, Math.max(0, room()));
        if (take.length === 0) return;
        try {
          const staged = await client.stageAttachments(take);
          dispatch({ type: "attached", files: staged.files, notice: staged.notice });
        } catch (e) {
          dispatch({ type: "attach-failed", message: `${refusedAll}: ${message(e)}` });
        }
      }),
    [client, guard],
  );

  const attachFiles = useCallback(
    (files: File[]) =>
      guard(async () => {
        for (const file of files.slice(0, Math.max(0, room()))) {
          try {
            const staged = await client.uploadAttachment(file, file.name || "arquivo");
            dispatch({ type: "attached", files: staged.files, notice: staged.notice });
          } catch (e) {
            dispatch({ type: "attach-failed", message: `${refusedAll}: ${message(e)}` });
          }
        }
      }),
    [client, guard],
  );

  const detach = useCallback(
    (path: string) => {
      dispatch({ type: "detached", path });
      void client.discardAttachment(path).catch(() => undefined);
    },
    [client],
  );

  const imageUrl = useCallback(
    (path: string) => {
      let url = images.current.get(path);
      if (!url) {
        url = client.attachmentImage(path).then((blob) => URL.createObjectURL(blob));
        url.catch(() => images.current.delete(path));
        images.current.set(path, url);
      }
      return url;
    },
    [client],
  );

  const refreshEngines = useCallback(
    () => client.engines().then((engines) => dispatch({ type: "engines", engines }), () => undefined),
    [client],
  );

  const chooseEngine = useCallback(
    (engine: EngineId) =>
      guard(async () => {
        await client.setEngine(engine);
        dispatch({ type: "engines", engines: await client.engines() });
      }),
    [client, guard],
  );

  const newConversation = useCallback(() => dispatch({ type: "reset-current" }), []);

  return {
    state,
    open,
    send,
    stop,
    answer,
    newConversation,
    rename,
    remove,
    reopen,
    attachPaths,
    attachFiles,
    detach,
    imageUrl,
    refreshEngines,
    chooseEngine,
  };
}
