import { useEffect, useRef, type KeyboardEvent } from "react";
import styles from "./Composer.module.css";

type Props = {
  value: string;
  onChange: (value: string) => void;
  onSend: (text: string) => void;
  onStop: () => void;
  thinking: boolean;
  autoFocus: boolean;
};

export function Composer({ value, onChange, onSend, onStop, thinking, autoFocus }: Props) {
  const area = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    if (autoFocus) area.current?.focus();
  }, [autoFocus]);

  useEffect(() => {
    const el = area.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 110)}px`;
  }, [value]);

  const submit = () => {
    const text = value.trim();
    if (!text || thinking) return;
    onSend(text);
    onChange("");
  };

  const onKeyDown = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault();
      submit();
    }
  };

  return (
    <div className={styles.composer}>
      <textarea
        ref={area}
        className={styles.input}
        rows={1}
        value={value}
        placeholder="Pergunte ao Wisp…"
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={onKeyDown}
      />
      {thinking ? (
        <button type="button" className={styles.stop} onClick={onStop} title="Parar">
          Parar
        </button>
      ) : (
        <button type="button" className={styles.send} onClick={submit} disabled={!value.trim()} title="Enviar (Enter)" aria-label="Enviar">
          ↑
        </button>
      )}
    </div>
  );
}
