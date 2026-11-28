import { useEffect, useRef } from "react";
import type { Block, Message } from "../../api/types";
import { attachmentsOf, summarize } from "../../state/attachments";
import { collectTools, liveOnlyTools } from "../../state/chat";
import { Markdown } from "../../components/Markdown";
import { AttachmentStack, type LoadImage } from "./AttachmentViews";
import { ToolBlock } from "./ToolBlock";
import styles from "./Transcript.module.css";

type Props = {
  messages: Message[];
  streaming: string;
  liveTools: Block[];
  notes?: string[];
  loadImage?: LoadImage;
};

const noImage: LoadImage = () => Promise.reject(new Error("no image loader"));

export function Transcript({ messages, streaming, liveTools, notes = [], loadImage = noImage }: Props) {
  const tools = collectTools(messages, liveTools);
  const extra = liveOnlyTools(messages, liveTools);
  const end = useRef<HTMLDivElement>(null);

  useEffect(() => {
    end.current?.scrollIntoView?.({ block: "end" });
  }, [messages.length, streaming, extra.length, notes.length]);

  return (
    <div className={styles.transcript} role="log">
      {messages.map((m, i) => (
        <MessageRow key={i} message={m} tools={tools} loadImage={loadImage} />
      ))}
      {extra.map((b) => {
        const entry = tools.get(b.id);
        return entry ? <ToolBlock key={b.id} entry={entry} /> : null;
      })}
      {streaming && (
        <div className={styles.assistant}>
          <Markdown text={streaming} />
        </div>
      )}
      {notes.map((note, i) => (
        <div key={i} className={styles.note}>
          {note}
        </div>
      ))}
      <div ref={end} />
    </div>
  );
}

function MessageRow({
  message,
  tools,
  loadImage,
}: {
  message: Message;
  tools: ReturnType<typeof collectTools>;
  loadImage: LoadImage;
}) {
  if (message.role === "user") {
    const text = message.blocks.flatMap((b) => (b.type === "text" ? [b.text] : [])).join("\n");
    if (!text) return null;
    const attached = attachmentsOf(text);
    if (!attached) return <div className={styles.user}>{text}</div>;
    if (attached.items.length === 0) return <div className={styles.user}>{summarize(attached)}</div>;
    return (
      <div className={styles.attached}>
        <AttachmentStack attachments={attached} loadImage={loadImage} />
        {attached.caption && <div className={styles.user}>{attached.caption}</div>}
      </div>
    );
  }
  return (
    <div className={styles.assistant}>
      {message.blocks.map((b, i) => {
        if (b.type === "text") return <Markdown key={i} text={b.text} />;
        if (b.type === "tool_use") {
          const entry = tools.get(b.id);
          return entry ? <ToolBlock key={b.id} entry={entry} /> : null;
        }
        return null;
      })}
    </div>
  );
}
