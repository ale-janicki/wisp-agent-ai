import { useEffect, useRef, type ClipboardEvent, type KeyboardEvent } from "react";
import type { StagedFile } from "../../api/types";
import { PendingAttachments } from "./AttachmentViews";
import styles from "./Composer.module.css";

type Props = {
  value: string;
  onChange: (value: string) => void;
  onSend: (text: string) => void;
  onStop: () => void;
  thinking: boolean;
  autoFocus: boolean;
  pending?: StagedFile[];
  notice?: string | null;
  disabled?: boolean;
  onAttachFiles?: (files: File[]) => void;
  onRemove?: (path: string) => void;
};

export function Composer({
  value,
  onChange,
  onSend,
  onStop,
  thinking,
  autoFocus,
  pending = [],
  notice = null,
  disabled = false,
  onAttachFiles,
  onRemove,
}: Props) {
  const area = useRef<HTMLTextAreaElement>(null);
  const picker = useRef<HTMLInputElement>(null);
  const canSend = !disabled && (value.trim() !== "" || pending.length > 0);

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
    if (!canSend) return;
    onSend(value.trim());
    onChange("");
  };

  const onKeyDown = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault();
      submit();
    }
  };

  const onPaste = (e: ClipboardEvent<HTMLTextAreaElement>) => {
    const files = Array.from(e.clipboardData?.files ?? []);
    if (files.length === 0 || !onAttachFiles || disabled) return;
    e.preventDefault();
    onAttachFiles(files);
  };

  return (
    <div className={`${styles.composer} ${disabled ? styles.disabled : ""}`}>
      {pending.length > 0 && onRemove && <PendingAttachments files={pending} onRemove={onRemove} />}
      {notice && <div className={styles.notice}>{notice}</div>}
      <div className={styles.row}>
        <button
          type="button"
          className={styles.clip}
          onClick={() => picker.current?.click()}
          disabled={disabled || !onAttachFiles}
          title="Anexar foto ou arquivo"
          aria-label="Anexar foto ou arquivo"
        >
          📎
        </button>
        <input
          ref={picker}
          type="file"
          multiple
          hidden
          data-testid="file-picker"
          onChange={(e) => {
            const files = Array.from(e.target.files ?? []);
            e.target.value = "";
            if (files.length > 0) onAttachFiles?.(files);
          }}
        />
        <textarea
          ref={area}
          className={styles.input}
          rows={1}
          value={value}
          disabled={disabled}
          placeholder="Pergunte ao Wisp…"
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={onKeyDown}
          onPaste={onPaste}
        />
        {thinking && (
          <button type="button" className={styles.stop} onClick={onStop} title="Parar">
            Parar
          </button>
        )}
        <button type="button" className={styles.send} onClick={submit} disabled={!canSend} title="Enviar (Enter)" aria-label="Enviar">
          ↑
        </button>
      </div>
    </div>
  );
}
