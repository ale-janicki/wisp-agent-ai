export type TreeEntry = { path: string; is_folder: boolean; modified: number; size: number };
export type NoteDoc = { path: string; kind: "note"; text: string; read_only: string | null; mtime: number };
export type OtherDoc = { path: string; kind: "drawing" | "image" | "other" };
export type Doc = NoteDoc | OtherDoc;
export type NoteSummary = { path: string; title: string; aliases: string[]; modified: number; link: string };
export type Hit = { path: string; title: string; snippet: string; score?: number };
export type Backlink = { path: string; title: string; contexts: { line: number; text: string }[] };
export type Outgoing = { name: string; heading: string; target: string | null };
export type Property = { key: string; value: string | string[]; kind: "text" | "list" | "complex" };
export type GraphData = { nodes: { id: string; title: string; degree: number }[]; edges: [string, string][] };
export type RenamePreview = {
  id: string;
  from: string;
  to: string;
  is_folder: boolean;
  is_complete: boolean;
  link_count: number;
  file_count: number;
  skipped: string[];
  drawings: string[];
  edits: { path: string; count: number }[];
};
export type DrawingDoc =
  | { kind: "excalidraw"; scene: string; files: Record<string, unknown>; hash: string; read_only: string | null }
  | { kind: "canvas"; canvas: CanvasData; hash: string; read_only: string | null };
export type CanvasNode = {
  id: string;
  type: "text" | "file" | "link" | "group";
  x: number;
  y: number;
  width: number;
  height: number;
  text?: string;
  file?: string;
  subpath?: string;
  url?: string;
  label?: string;
  color?: string;
};
export type CanvasEdge = { id: string; fromNode: string; toNode: string; fromSide?: string; toSide?: string; label?: string; color?: string };
export type CanvasData = { nodes: CanvasNode[]; edges: CanvasEdge[] };
