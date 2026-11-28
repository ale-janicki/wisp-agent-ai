import { createContext, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import type { BrainApi } from "./api";
import { headingSection, parseHref, prepare } from "./markdown";
import type { Outgoing } from "./types";
import styles from "./Reader.module.css";

export type Focus = { line?: number; heading?: string } | null;

type Props = {
  api: BrainApi;
  path: string;
  text: string;
  depth?: number;
  focus?: Focus;
  onLink: (name: string, heading: string, from: string, newTab: boolean) => void;
  onTag: (tag: string) => void;
  onOpenDrawing: (name: string, from: string) => void;
  onToggle?: (line: number) => void;
};

const MAX_EMBED_DEPTH = 3;

function AttachmentImage({ api, name, from, width }: { api: BrainApi; name: string; from: string; width?: number }) {
  const [src, setSrc] = useState<string | null>(null);
  const [missing, setMissing] = useState(false);
  useEffect(() => {
    let alive = true;
    api
      .attachment(name, from)
      .then((file) => alive && setSrc(`data:${file.mime};base64,${file.data}`))
      .catch(() => alive && setMissing(true));
    return () => {
      alive = false;
    };
  }, [api, name, from]);
  if (missing) return <span className={styles.missing}>Não encontrei {name}</span>;
  return src ? <img src={src} alt={name} style={width ? { width } : undefined} className={styles.image} /> : <span className={styles.missing}>…</span>;
}

function Embed({ api, target, from, depth, props }: { api: BrainApi; target: string; from: string; depth: number; props: Props }) {
  const [open, setOpen] = useState(true);
  const [state, setState] = useState<{ path: string; text: string } | "missing" | null>(null);
  const name = target.split("#")[0] ?? "";
  const heading = target.split("#").slice(1).join("#");
  useEffect(() => {
    if (!open || depth >= MAX_EMBED_DEPTH) return;
    let alive = true;
    (async () => {
      try {
        const path = await api.resolve(name, from);
        if (!path) return alive && setState("missing");
        const doc = await api.note(path);
        if (doc.kind !== "note") return alive && setState("missing");
        const text = heading ? headingSection(doc.text, heading) : doc.text;
        if (alive) setState(text ? { path, text } : "missing");
      } catch {
        if (alive) setState("missing");
      }
    })();
    return () => {
      alive = false;
    };
  }, [api, name, heading, from, open, depth]);
  if (depth >= MAX_EMBED_DEPTH) return <span className={styles.missing}>Limite de notas dentro de notas.</span>;
  return (
    <span className={styles.embed}>
      <button type="button" className={styles.embedHead} onClick={() => setOpen(!open)} aria-expanded={open}>
        {open ? "▾" : "▸"} {target}
      </button>
      {open && state === "missing" && <span className={styles.missing}>Não encontrei {name}</span>}
      {open && state && state !== "missing" && (
        <Reader {...props} path={state.path} text={state.text} depth={depth + 1} onToggle={undefined} focus={null} />
      )}
    </span>
  );
}

type Positioned = { position?: { start: { line: number } } };

const LineContext = createContext<number | undefined>(undefined);
const UnresolvedContext = createContext<ReadonlySet<string>>(new Set());

function Wikilink({ name, heading, value, from, onLink, children }: {
  name: string;
  heading: string;
  value: string;
  from: string;
  onLink: Props["onLink"];
  children?: ReactNode;
}) {
  const missing = useContext(UnresolvedContext).has(name.toLowerCase());
  return (
    <a
      href="#"
      className={missing ? styles.unresolved : styles.link}
      title={missing ? "Nota que ainda não existe; clique para criar" : value}
      onClick={(e) => {
        e.preventDefault();
        onLink(name, heading, from, e.ctrlKey || e.metaKey);
      }}
    >
      {children}
    </a>
  );
}

function TaskBox({ checked, onToggle }: { checked: boolean; onToggle?: (line: number) => void }) {
  const line = useContext(LineContext);
  return (
    <input
      type="checkbox"
      checked={checked}
      disabled={!onToggle || line === undefined}
      onChange={() => line !== undefined && onToggle?.(line - 1)}
    />
  );
}

export function Reader(props: Props) {
  const { api, path, text, depth = 0, focus } = props;
  const [outgoing, setOutgoing] = useState<Outgoing[]>([]);
  const root = useRef<HTMLDivElement>(null);
  const latest = useRef(props);
  latest.current = props;
  const prepared = useMemo(() => prepare(text), [text]);

  useEffect(() => {
    if (depth > 0) return;
    let alive = true;
    api
      .outgoing(path)
      .then((items) => alive && setOutgoing(items))
      .catch(() => alive && setOutgoing([]));
    return () => {
      alive = false;
    };
  }, [api, path, text, depth]);

  const unresolved = useMemo(() => new Set(outgoing.filter((o) => o.target === null).map((o) => o.name.toLowerCase())), [outgoing]);

  useEffect(() => {
    const host = root.current;
    if (!host || !focus) return;
    if (focus.heading) {
      const wanted = focus.heading.trim().toLowerCase();
      const found = [...host.querySelectorAll("h1,h2,h3,h4,h5,h6")].find((h) => h.textContent?.trim().toLowerCase() === wanted);
      found?.scrollIntoView?.({ block: "start" });
    } else if (focus.line !== undefined) {
      const wanted = focus.line + 1;
      const blocks = [...host.querySelectorAll<HTMLElement>("[data-line]")];
      const found = blocks.find((b) => Number(b.dataset.line) >= wanted) ?? blocks[blocks.length - 1];
      found?.scrollIntoView?.({ block: "center" });
    }
  }, [focus, prepared]);

  const components = useMemo((): Components => {
    const lined =
      (Tag: "p" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "blockquote") =>
      ({ node, children }: { node?: Positioned; children?: ReactNode }) => <Tag data-line={node?.position?.start.line}>{children}</Tag>;
    return {
      p: lined("p"),
      h1: lined("h1"),
      h2: lined("h2"),
      h3: lined("h3"),
      h4: lined("h4"),
      h5: lined("h5"),
      h6: lined("h6"),
      blockquote: lined("blockquote"),
      li: ({ node, children }: { node?: Positioned; children?: ReactNode }) => (
        <LineContext.Provider value={node?.position?.start.line}>
          <li data-line={node?.position?.start.line}>{children}</li>
        </LineContext.Provider>
      ),
      input: ({ checked, type }) =>
        type === "checkbox" ? <TaskBox checked={!!checked} onToggle={latest.current.onToggle} /> : <input type={type} readOnly />,
      img: ({ src, alt }) => {
        const href = parseHref(typeof src === "string" ? src : undefined);
        if (href?.kind === "file") return <AttachmentImage api={api} name={href.value} from={path} width={href.width} />;
        return <span className={styles.missing}>{alt}</span>;
      },
      a: ({ href, children }) => {
        const target = parseHref(href);
        if (!target) return <span>{children}</span>;
        if (target.kind === "note") {
          const [name = "", ...rest] = target.value.split("#");
          return (
            <Wikilink name={name} heading={rest.join("#")} value={target.value} from={path} onLink={(...args) => latest.current.onLink(...args)}>
              {children}
            </Wikilink>
          );
        }
        if (target.kind === "tag")
          return (
            <button type="button" className={styles.tag} onClick={() => latest.current.onTag(target.value)}>
              {children}
            </button>
          );
        if (target.kind === "draw")
          return (
            <button type="button" className={styles.tag} onClick={() => latest.current.onOpenDrawing(target.value, path)}>
              {children}
            </button>
          );
        if (target.kind === "embed") return <Embed api={api} target={target.value} from={path} depth={depth} props={latest.current} />;
        if (target.kind === "web")
          return (
            <a href={target.value} target="_blank" rel="noreferrer noopener" className={styles.link}>
              {children}
            </a>
          );
        return <span>{children}</span>;
      },
    };
  }, [api, path, depth]);

  return (
    <div ref={root} className={styles.reader} data-depth={depth}>
      <UnresolvedContext.Provider value={unresolved}>
        <ReactMarkdown remarkPlugins={REMARK} urlTransform={keepUrl} components={components}>
          {prepared}
        </ReactMarkdown>
      </UnresolvedContext.Provider>
    </div>
  );
}

const REMARK = [remarkGfm];
const keepUrl = (url: string) => url;
