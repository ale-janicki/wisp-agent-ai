import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError } from "../../api/client";
import { useFeatureEvents } from "../../shell/context";
import type { BrainApi } from "./api";
import type { NoteDoc } from "./types";

export const AUTOSAVE_MS = 800;
export type Banner = { kind: "conflict" | "deleted"; disk: string } | null;
export type Choice = "merge" | "disk" | "mine";

const MINE_MARKER = "<<<<<<< minhas edições";
const THEIRS_MARKER = ">>>>>>> no disco";
export const hasMergeMarkers = (text: string): boolean => {
  const lines = text.split("\n").map((l) => l.replace(/\r$/, ""));
  return lines.includes(MINE_MARKER) && lines.includes(THEIRS_MARKER);
};

const describe = (e: unknown) => (e instanceof ApiError ? `erro ${e.status}` : e instanceof Error ? e.message : String(e));

export function useNoteDoc(api: BrainApi, path: string, onGone: (path: string) => void) {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [readOnly, setReadOnly] = useState<string | null>(null);
  const [text, setTextState] = useState("");
  const [base, setBaseState] = useState("");
  const [banner, setBannerState] = useState<Banner>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [revision, setRevision] = useState(0);
  const textRef = useRef("");
  const baseRef = useRef("");
  const bannerRef = useRef<Banner>(null);
  const readOnlyRef = useRef<string | null>(null);
  const allowMarkers = useRef(false);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const gone = useRef(onGone);
  gone.current = onGone;

  const setBase = (value: string) => {
    baseRef.current = value;
    setBaseState(value);
    setRevision((n) => n + 1);
  };
  const setText = (value: string) => {
    textRef.current = value;
    setTextState(value);
  };
  const setBanner = (value: Banner) => {
    bannerRef.current = value;
    setBannerState(value);
  };

  const fetchNote = useCallback(async (): Promise<NoteDoc | null> => {
    const doc = await api.note(path);
    return doc.kind === "note" ? doc : null;
  }, [api, path]);

  const save = useCallback(async () => {
    clearTimeout(timer.current);
    if (readOnlyRef.current || bannerRef.current || textRef.current === baseRef.current) return;
    if (hasMergeMarkers(textRef.current) && !allowMarkers.current) return;
    const sent = textRef.current;
    try {
      await api.save(path, sent, baseRef.current);
      setBase(sent);
      setSaveError(null);
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) return setBanner({ kind: "deleted", disk: "" });
      if (e instanceof ApiError && e.status === 409) return void (await settle());
      setSaveError(`Não consegui salvar: ${describe(e)}`);
    }
  }, [api, path]);

  const settle = useCallback(async () => {
    try {
      const disk = await fetchNote();
      if (!disk) return;
      if (disk.text === textRef.current) return setBase(disk.text);
      if (textRef.current === baseRef.current) {
        setText(disk.text);
        return setBase(disk.text);
      }
      if (disk.text !== baseRef.current) setBanner({ kind: "conflict", disk: disk.text });
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) {
        if (textRef.current !== baseRef.current) setBanner({ kind: "deleted", disk: "" });
        else gone.current(path);
      }
    }
  }, [fetchNote, path]);

  const saveAnyway = useCallback(() => {
    allowMarkers.current = true;
    void save();
  }, [save]);

  const edit = useCallback(
    (value: string) => {
      setText(value);
      if (!hasMergeMarkers(value)) allowMarkers.current = false;
      clearTimeout(timer.current);
      if (!readOnlyRef.current && !bannerRef.current) timer.current = setTimeout(() => void save(), AUTOSAVE_MS);
    },
    [save],
  );

  useEffect(() => {
    let alive = true;
    setLoading(true);
    setError(null);
    setBanner(null);
    setSaveError(null);
    (async () => {
      try {
        const doc = await fetchNote();
        if (!alive || !doc) return;
        readOnlyRef.current = doc.read_only;
        setReadOnly(doc.read_only);
        setText(doc.text);
        setBase(doc.text);
      } catch (e) {
        if (alive) setError(e instanceof ApiError && e.status === 404 ? "Nota não encontrada" : `Não consegui ler ${path}: ${describe(e)}`);
      } finally {
        if (alive) setLoading(false);
      }
    })();
    return () => {
      alive = false;
      clearTimeout(timer.current);
      void save();
    };
  }, [fetchNote, path, save]);

  useFeatureEvents("brain", (event) => {
    const paths = event.paths;
    if (event.type === "changed" && Array.isArray(paths) && paths.includes(path) && !loading) void settle();
  });

  const resolve = useCallback(
    async (choice: Choice) => {
      const current = bannerRef.current;
      if (!current) return;
      const mine = textRef.current;
      try {
        if (current.kind === "deleted") {
          await api.create(path, mine);
          setBanner(null);
          return setBase(mine);
        }
        if (choice === "merge") {
          const merged = await api.merge(baseRef.current, mine, current.disk);
          setBase(current.disk);
          if (merged.kind !== "unchanged") setText(merged.text);
          setBanner(null);
          timer.current = setTimeout(() => void save(), AUTOSAVE_MS);
        } else if (choice === "disk") {
          await api.recover(path, mine);
          setText(current.disk);
          setBase(current.disk);
          setBanner(null);
        } else {
          await api.recover(path, current.disk);
          await api.save(path, mine, undefined, true);
          setBase(mine);
          setBanner(null);
        }
      } catch (e) {
        setSaveError(`Não consegui resolver: ${describe(e)}`);
      }
    },
    [api, path, save],
  );

  const replace = useCallback((value: string) => {
    setText(value);
    setBase(value);
  }, []);

  const markers = hasMergeMarkers(text) && !allowMarkers.current;
  return { loading, error, readOnly, text, base, revision, dirty: text !== base, banner, saveError, markers, edit, save, saveAnyway, resolve, replace };
}
