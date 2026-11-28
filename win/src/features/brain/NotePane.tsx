import { useCallback, useState } from "react";
import { ApiError } from "../../api/client";
import type { BrainApi } from "./api";
import { Backlinks } from "./Backlinks";
import { Editor } from "./Editor";
import { Properties } from "./Properties";
import { Reader, type Focus } from "./Reader";
import { useNoteDoc } from "./useNoteDoc";
import type { NoteSummary } from "./types";
import styles from "./NotePane.module.css";

type Props = {
  api: BrainApi;
  path: string;
  focus: Focus;
  editing: boolean;
  notes: NoteSummary[];
  tags: Record<string, number>;
  version: string;
  bookmarked: boolean;
  onEditing: (value: boolean) => void;
  onLink: (name: string, heading: string, from: string, newTab: boolean) => void;
  onTag: (tag: string) => void;
  onOpenDrawing: (name: string, from: string) => void;
  onOpenAt: (path: string, line: number) => void;
  onGone: (path: string) => void;
  onRename: () => void;
  onDelete: () => void;
  onBookmark: () => void;
  onAsk: (text: string) => void;
};

export function NotePane(props: Props) {
  const { api, path, focus, editing, notes, tags, version, bookmarked, onEditing, onLink, onTag, onOpenDrawing, onOpenAt, onGone } = props;
  const doc = useNoteDoc(api, path, onGone);
  const [menu, setMenu] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);

  const toggleTask = useCallback(
    async (line: number) => {
      setNotice(null);
      try {
        await doc.save();
        const expected = doc.text.split("\n")[line] ?? "";
        doc.replace((await api.toggleTask(path, line, expected)).text);
      } catch (e) {
        setNotice(e instanceof ApiError && e.status === 409 ? "A nota mudou; atualizei a tela e não marquei nada." : "Não consegui marcar a tarefa.");
      }
    },
    [api, path, doc],
  );

  if (doc.loading) return <p className={styles.message}>Lendo notas…</p>;
  if (doc.error) return <p className={styles.message}>{doc.error}</p>;

  const title = path.slice(path.lastIndexOf("/") + 1).replace(/\.md$/i, "");
  const readOnly = doc.readOnly !== null || doc.banner !== null;
  const reading = !editing || doc.readOnly !== null;

  return (
    <div className={styles.pane}>
      <header className={styles.head}>
        <h3 className={styles.title} title={path}>
          {title}
        </h3>
        <span className={styles.actions}>
          {doc.dirty && <span className={styles.dirty}>Salvando…</span>}
          <button type="button" onClick={() => onEditing(!editing)} disabled={doc.readOnly !== null} title="Alternar entre ler e editar (Ctrl+E)">
            {reading ? "Editar (Ctrl+E)" : "Ler (Ctrl+E)"}
          </button>
          <span className={styles.menuHost}>
            <button type="button" aria-label="Mais ações" aria-expanded={menu} onClick={() => setMenu(!menu)}>
              ⋯
            </button>
            {menu && (
              <ul className={styles.menu} role="menu" onClick={() => setMenu(false)}>
                <li>
                  <button type="button" role="menuitem" onClick={props.onRename}>
                    Renomear ou mover…
                  </button>
                </li>
                <li>
                  <button type="button" role="menuitem" onClick={props.onBookmark}>
                    {bookmarked ? "Remover dos favoritos" : "Favoritar"}
                  </button>
                </li>
                <li>
                  <button type="button" role="menuitem" onClick={() => props.onAsk(doc.text)}>
                    Perguntar ao Wisp sobre esta nota…
                  </button>
                </li>
                <li>
                  <button type="button" role="menuitem" onClick={props.onDelete}>
                    Mover para o Lixo
                  </button>
                </li>
              </ul>
            )}
          </span>
        </span>
      </header>
      {doc.readOnly && <p className={styles.warn}>Somente leitura: {doc.readOnly}</p>}
      {notice && <p className={styles.warn}>{notice}</p>}
      {doc.saveError && <p className={styles.warn}>{doc.saveError}</p>}
      {doc.markers && (
        <div className={styles.banner} role="alert">
          <span>Resolver conflitos: o texto tem marcadores de mesclagem e não será salvo até você removê-los.</span>
          <button type="button" onClick={doc.saveAnyway}>
            Salvar mesmo assim
          </button>
        </div>
      )}
      {doc.banner?.kind === "conflict" && (
        <div className={styles.banner} role="alert">
          <span>Esta nota mudou no disco (git, outro editor ou o agente) e você tem edições aqui.</span>
          <button type="button" onClick={() => void doc.resolve("merge")}>
            Mesclar
          </button>
          <button type="button" onClick={() => void doc.resolve("disk")}>
            Usar a do disco
          </button>
          <button type="button" onClick={() => void doc.resolve("mine")}>
            Manter a minha
          </button>
          <small>O texto descartado fica guardado em brain-recuperado, ao lado da pasta do Wisp.</small>
        </div>
      )}
      {doc.banner?.kind === "deleted" && (
        <div className={styles.banner} role="alert">
          <span>Esta nota foi apagada ou movida fora do Wisp, e você tem texto que ainda não foi salvo.</span>
          <button type="button" onClick={() => void doc.resolve("mine")}>
            Recriar com meu texto
          </button>
        </div>
      )}
      <div className={styles.scroll}>
        {reading && (
          <Properties
            api={api}
            path={path}
            disabled={readOnly}
            version={`${version}:${doc.revision}`}
            beforeEdit={doc.save}
            onText={doc.replace}
            onTag={onTag}
          />
        )}
        {reading ? (
          <Reader
            api={api}
            path={path}
            text={doc.text}
            focus={focus}
            onLink={onLink}
            onTag={onTag}
            onOpenDrawing={onOpenDrawing}
            onToggle={readOnly ? undefined : (line) => void toggleTask(line)}
          />
        ) : (
          <Editor text={doc.text} readOnly={readOnly} notes={notes} tags={tags} focusLine={focus?.line} onChange={doc.edit} />
        )}
        <Backlinks api={api} path={path} version={version} onOpen={onOpenAt} />
      </div>
    </div>
  );
}
