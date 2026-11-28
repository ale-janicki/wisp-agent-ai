import { useShell } from "../../shell/context";
import { Composer } from "./Composer";
import { ConversationList } from "./ConversationList";
import { PermissionCard } from "./PermissionCard";
import { Transcript } from "./Transcript";
import styles from "./ConversaTab.module.css";

export function ConversaTab() {
  const { session, draft, setDraft, focusComposer } = useShell();
  const chat = session.state;
  const mine = chat.permissions.filter((r) => r.conversationId === chat.currentId);
  const attention = new Set(chat.permissions.map((r) => r.conversationId));
  const thinking = chat.currentId !== null && chat.status[chat.currentId] === "thinking";
  const request = mine[0];

  return (
    <div className={styles.conversa}>
      <ConversationList
        items={chat.conversations}
        currentId={chat.currentId}
        status={chat.status}
        attention={attention}
        onOpen={(id) => void session.open(id)}
        onNew={session.newConversation}
      />
      <section className={styles.chat}>
        <header className={styles.header}>
          <span className={styles.title}>{chat.title || "Nova conversa"}</span>
          {thinking && <span className={styles.step}>{request ? "esperando tua aprovação" : "Pensando…"}</span>}
        </header>
        <Transcript messages={chat.messages} streaming={chat.streaming} liveTools={chat.liveTools} />
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
              onAnswer={(allow) => void session.answer(request.requestId, allow)}
            />
          </div>
        )}
        <Composer
          value={draft}
          onChange={setDraft}
          onSend={(t) => void session.send(t)}
          onStop={() => void session.stop()}
          thinking={thinking}
          autoFocus={focusComposer}
        />
      </section>
    </div>
  );
}
