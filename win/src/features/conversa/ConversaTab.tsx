import { useEffect } from "react";
import { useShell } from "../../shell/context";
import { Composer } from "./Composer";
import { ConversationList } from "./ConversationList";
import { EnginePicker } from "./EnginePicker";
import { PermissionCard } from "./PermissionCard";
import { Transcript } from "./Transcript";
import { UsageIndicator } from "./UsageIndicator";
import { useFileDrop } from "./useFileDrop";
import styles from "./ConversaTab.module.css";

export function ConversaTab() {
  const { session, draft, setDraft, focusComposer } = useShell();
  const chat = session.state;
  const mine = chat.permissions.filter((r) => r.conversationId === chat.currentId);
  const attention = new Set([...chat.permissions.map((r) => r.conversationId), ...chat.unseen]);
  const thinking = chat.currentId !== null && chat.status[chat.currentId] === "thinking";
  const request = mine[0];
  const notes = chat.currentId ? (chat.notes[chat.currentId] ?? []) : [];
  const empty = chat.messages.length === 0 && !thinking && !chat.streaming && notes.length === 0 && !chat.error;
  const { refreshEngines, attachPaths } = session;
  const dropping = useFileDrop(attachPaths, !chat.closed);
  const enginesKnown = chat.engines !== null;

  useEffect(() => {
    if (!enginesKnown) void refreshEngines();
  }, [enginesKnown, refreshEngines]);

  return (
    <div className={`${styles.conversa} ${dropping ? styles.dropping : ""}`}>
      <ConversationList
        items={chat.conversations}
        currentId={chat.currentId}
        status={chat.status}
        attention={attention}
        onOpen={(id) => void session.open(id)}
        onNew={session.newConversation}
        onDelete={(id) => void session.remove(id)}
        onRename={(id, title) => void session.rename(id, title)}
      />
      <section className={styles.chat}>
        <header className={styles.header}>
          <span className={styles.title}>{chat.title || "Nova conversa"}</span>
          {thinking && <span className={styles.step}>{request ? "esperando tua aprovação" : "Pensando…"}</span>}
          <span className={styles.spacer} />
          <UsageIndicator usage={chat.usage} />
          <EnginePicker overview={chat.engines} onChoose={(engine) => void session.chooseEngine(engine)} />
        </header>
        {empty ? (
          <div className={styles.empty}>Pergunte qualquer coisa ao Wisp</div>
        ) : (
          <Transcript
            messages={chat.messages}
            streaming={chat.streaming}
            liveTools={chat.liveTools}
            notes={notes}
            loadImage={session.imageUrl}
          />
        )}
        {chat.error && (
          <div className={styles.error} role="alert">
            {chat.error}
          </div>
        )}
        {request && (
          <div className={styles.permission}>
            <PermissionCard
              key={request.requestId}
              request={request}
              queued={mine.length - 1}
              onAnswer={(allow, always) => void session.answer(request.requestId, allow, undefined, always)}
            />
          </div>
        )}
        {chat.closed && chat.currentId ? (
          <div className={styles.closedBar}>
            <span>Conversa encerrada — só leitura</span>
            <button type="button" onClick={() => void session.reopen(chat.currentId!)}>
              Reabrir
            </button>
          </div>
        ) : (
          <Composer
            value={draft}
            onChange={setDraft}
            onSend={(t) => void session.send(t)}
            onStop={() => void session.stop()}
            thinking={thinking}
            autoFocus={focusComposer}
            pending={chat.pending}
            notice={chat.attachNotice}
            onAttachFiles={(files) => void session.attachFiles(files)}
            onRemove={session.detach}
          />
        )}
      </section>
    </div>
  );
}
