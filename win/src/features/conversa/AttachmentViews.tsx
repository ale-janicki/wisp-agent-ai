import { useEffect, useState } from "react";
import { displayName, formatBytes, isImage, type AttachmentItem, type ParsedAttachments } from "../../state/attachments";
import type { StagedFile } from "../../api/types";
import styles from "./AttachmentViews.module.css";

export type LoadImage = (path: string) => Promise<string>;

export function AttachmentStack({ attachments, loadImage }: { attachments: ParsedAttachments; loadImage: LoadImage }) {
  return (
    <div className={styles.stack}>
      {attachments.items.map((item, i) => (
        <AttachmentTile key={i} item={item} loadImage={loadImage} />
      ))}
    </div>
  );
}

function AttachmentTile({ item, loadImage }: { item: AttachmentItem; loadImage: LoadImage }) {
  if (item.kind === "failed") return <Chip title={item.label} detail="não baixou" warn />;
  if (isImage(item.name)) return <ImageTile path={item.path} name={displayName(item.name)} loadImage={loadImage} />;
  return <Chip title={displayName(item.name)} detail={formatBytes(item.bytes)} />;
}

function ImageTile({ path, name, loadImage }: { path: string; name: string; loadImage: LoadImage }) {
  const [url, setUrl] = useState<string | null>(null);
  const [missing, setMissing] = useState(false);

  useEffect(() => {
    let live = true;
    loadImage(path).then(
      (u) => live && setUrl(u),
      () => live && setMissing(true),
    );
    return () => {
      live = false;
    };
  }, [path, loadImage]);

  if (url) return <img className={styles.image} src={url} alt={name} />;
  return (
    <div className={styles.placeholder} role="img" aria-label={name}>
      {missing ? "foto no outro computador" : "…"}
    </div>
  );
}

function Chip({ title, detail, warn = false }: { title: string; detail: string; warn?: boolean }) {
  return (
    <div className={styles.chip}>
      <span className={`${styles.icon} ${warn ? styles.warn : ""}`} aria-hidden>
        {warn ? "!" : "▤"}
      </span>
      <span className={styles.text}>
        <span className={styles.name}>{title}</span>
        <span className={styles.detail}>{detail}</span>
      </span>
    </div>
  );
}

export function PendingAttachments({ files, onRemove }: { files: StagedFile[]; onRemove: (path: string) => void }) {
  return (
    <div className={styles.pending}>
      {files.map((f) => (
        <div className={styles.tile} key={f.path}>
          <span className={styles.tileIcon} aria-hidden>
            {f.image ? "▣" : "▤"}
          </span>
          <span className={styles.tileName}>{displayName(f.name)}</span>
          <button type="button" className={styles.remove} onClick={() => onRemove(f.path)} title="Remover" aria-label={`Remover ${displayName(f.name)}`}>
            ✕
          </button>
        </div>
      ))}
    </div>
  );
}
