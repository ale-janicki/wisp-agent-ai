import { useEffect, useRef } from "react";
import type { Block, Message } from "../api/types";
import { collectTools, liveOnlyTools } from "../state/chat";
import { Markdown } from "./Markdown";
import { ToolBlock } from "./ToolBlock";
import styles from "./Transcript.module.css";

type Props = { messages: Message[]; streaming: string; liveTools: Block[] };

export function Transcript({ messages, streaming, liveTools }: Props) {
  const tools = collectTools(messages, liveTools);
  const extra = liveOnlyTools(messages, liveTools);
  const end = useRef<HTMLDivElement>(null);

  useEffect(() => {
    end.current?.scrollIntoView?.({ block: "end" });
  }, [messages.length, streaming, extra.length]);

  return (
    <div className={styles.transcript} role="log">
      {messages.map((m, i) => (
        <MessageRow key={i} message={m} tools={tools} />
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
      <div ref={end} />
    </div>
  );
}

function MessageRow({ message, tools }: { message: Message; tools: ReturnType<typeof collectTools> }) {
  if (message.role === "user") {
    const text = message.blocks.flatMap((b) => (b.type === "text" ? [b.text] : [])).join("\n");
    if (!text) return null;
    return <div className={styles.user}>{text}</div>;
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
