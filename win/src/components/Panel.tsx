import type { ChatState } from "../state/chat";
import { Composer } from "./Composer";
import { ConversationList } from "./ConversationList";
import { PermissionCard } from "./PermissionCard";
import { Transcript } from "./Transcript";
import styles from "./Panel.module.css";

type Props = {
  chat: ChatState;
  draft: string;
  focusComposer: boolean;
  onDraft: (value: string) => void;
  onOpen: (id: string) => void;
  onNew: () => void;
  onSend: (text: string) => void;
  onStop: () => void;
  onAnswer: (requestId: string, allow: boolean) => void;
  onMouseEnter: () => void;
  onMouseLeave: () => void;
};

export function Panel(p: Props) {
  const { chat } = p;
  const mine = chat.permissions.filter((r) => r.conversationId === chat.currentId);
  const attention = new Set(chat.permissions.map((r) => r.conversationId));
  const thinking = chat.currentId !== null && chat.status[chat.currentId] === "thinking";
  const request = mine[0];

  return (
    <div className={styles.panel} onMouseEnter={p.onMouseEnter} onMouseLeave={p.onMouseLeave}>
      <ConversationList
        items={chat.conversations}
        currentId={chat.currentId}
        status={chat.status}
        attention={attention}
        onOpen={p.onOpen}
        onNew={p.onNew}
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
              onAnswer={(allow) => p.onAnswer(request.requestId, allow)}
            />
          </div>
        )}
        <Composer
          value={p.draft}
          onChange={p.onDraft}
          onSend={p.onSend}
          onStop={p.onStop}
          thinking={thinking}
          autoFocus={p.focusComposer}
        />
      </section>
    </div>
  );
}
