import { useMemo, useRef, useState } from "react";
import type { CanvasData, CanvasEdge, CanvasNode } from "./types";
import styles from "./Drawing.module.css";

const PRESET: Record<string, string> = { "1": "#f2555a", "2": "#f5a03d", "3": "#f5d23d", "4": "#5bd66e", "5": "#4cc9d6", "6": "#a98bf0" };
const color = (value?: string) => (value ? (PRESET[value] ?? value) : undefined);

type Point = { x: number; y: number };
const SIDES = ["top", "right", "bottom", "left"] as const;

function anchor(node: CanvasNode, side: string): Point {
  const cx = node.x + node.width / 2;
  const cy = node.y + node.height / 2;
  if (side === "top") return { x: cx, y: node.y };
  if (side === "bottom") return { x: cx, y: node.y + node.height };
  if (side === "left") return { x: node.x, y: cy };
  return { x: node.x + node.width, y: cy };
}

function facing(from: CanvasNode, to: CanvasNode): string {
  const dx = to.x + to.width / 2 - (from.x + from.width / 2);
  const dy = to.y + to.height / 2 - (from.y + from.height / 2);
  return Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? "right" : "left") : dy > 0 ? "bottom" : "top";
}

const pull = (point: Point, side: string, amount: number): Point => ({
  x: point.x + (side === "right" ? amount : side === "left" ? -amount : 0),
  y: point.y + (side === "bottom" ? amount : side === "top" ? -amount : 0),
});

function Edge({ edge, nodes }: { edge: CanvasEdge; nodes: Map<string, CanvasNode> }) {
  const from = nodes.get(edge.fromNode);
  const to = nodes.get(edge.toNode);
  if (!from || !to) return null;
  const fromSide = SIDES.includes(edge.fromSide as (typeof SIDES)[number]) ? edge.fromSide! : facing(from, to);
  const toSide = SIDES.includes(edge.toSide as (typeof SIDES)[number]) ? edge.toSide! : facing(to, from);
  const a = anchor(from, fromSide);
  const b = anchor(to, toSide);
  const reach = Math.max(40, Math.hypot(b.x - a.x, b.y - a.y) / 3);
  const c1 = pull(a, fromSide, reach);
  const c2 = pull(b, toSide, reach);
  const stroke = color(edge.color) ?? "#9a9ba1";
  return (
    <g>
      <path d={`M${a.x},${a.y} C${c1.x},${c1.y} ${c2.x},${c2.y} ${b.x},${b.y}`} fill="none" stroke={stroke} strokeWidth={2} markerEnd="url(#arrow)" />
      {edge.label && (
        <text x={(a.x + b.x) / 2} y={(a.y + b.y) / 2} fill="#f2f2f3" fontSize={13} textAnchor="middle">
          {edge.label}
        </text>
      )}
    </g>
  );
}

export function CanvasView({ data, onOpenNote }: { data: CanvasData; onOpenNote: (target: string) => void }) {
  const host = useRef<HTMLDivElement>(null);
  const [view, setView] = useState({ x: 0, y: 0, k: 1 });
  const drag = useRef<Point | null>(null);
  const nodes = useMemo(() => new Map(data.nodes.map((n) => [n.id, n])), [data]);

  const fit = () => {
    const box = host.current;
    if (!box || data.nodes.length === 0) return setView({ x: 0, y: 0, k: 1 });
    const minX = Math.min(...data.nodes.map((n) => n.x));
    const minY = Math.min(...data.nodes.map((n) => n.y));
    const maxX = Math.max(...data.nodes.map((n) => n.x + n.width));
    const maxY = Math.max(...data.nodes.map((n) => n.y + n.height));
    const k = Math.min(box.clientWidth / (maxX - minX + 80), box.clientHeight / (maxY - minY + 80), 2) || 1;
    setView({ k, x: box.clientWidth / 2 - ((minX + maxX) / 2) * k, y: box.clientHeight / 2 - ((minY + maxY) / 2) * k });
  };

  return (
    <div className={styles.canvasWrap}>
      <div className={styles.canvasTools}>
        <button type="button" onClick={() => setView((v) => ({ ...v, k: v.k * 1.2 }))} aria-label="Ampliar">
          +
        </button>
        <button type="button" onClick={() => setView((v) => ({ ...v, k: v.k / 1.2 }))} aria-label="Reduzir">
          −
        </button>
        <button type="button" onClick={fit}>
          Ajustar
        </button>
      </div>
      <div
        ref={host}
        className={styles.canvas}
        onMouseDown={(e) => (drag.current = { x: e.clientX, y: e.clientY })}
        onMouseMove={(e) => {
          if (!drag.current) return;
          const dx = e.clientX - drag.current.x;
          const dy = e.clientY - drag.current.y;
          drag.current = { x: e.clientX, y: e.clientY };
          setView((v) => ({ ...v, x: v.x + dx, y: v.y + dy }));
        }}
        onMouseUp={() => (drag.current = null)}
        onMouseLeave={() => (drag.current = null)}
        onWheel={(e) => setView((v) => ({ ...v, k: Math.max(0.05, v.k * (e.deltaY < 0 ? 1.1 : 1 / 1.1)) }))}
      >
        <svg width="100%" height="100%" role="img" aria-label="Canvas">
          <defs>
            <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
              <path d="M0,0 L10,5 L0,10 z" fill="#9a9ba1" />
            </marker>
          </defs>
          <g transform={`translate(${view.x} ${view.y}) scale(${view.k})`}>
            {data.nodes
              .filter((n) => n.type === "group")
              .map((n) => (
                <g key={n.id}>
                  <rect x={n.x} y={n.y} width={n.width} height={n.height} rx={12} fill="rgba(255,255,255,0.03)" stroke={color(n.color) ?? "#6b6c72"} strokeDasharray="6 4" />
                  {n.label && (
                    <text x={n.x + 10} y={n.y + 20} fill="#9a9ba1" fontSize={14}>
                      {n.label}
                    </text>
                  )}
                </g>
              ))}
            {data.edges.map((e) => (
              <Edge key={e.id} edge={e} nodes={nodes} />
            ))}
            {data.nodes
              .filter((n) => n.type !== "group")
              .map((n) => {
                const target = n.type === "file" ? `${n.file ?? ""}${n.subpath ?? ""}` : null;
                return (
                  <g
                    key={n.id}
                    style={{ cursor: target || n.type === "link" ? "pointer" : "default" }}
                    onClick={() => {
                      if (target) onOpenNote(target);
                      else if (n.type === "link" && n.url && /^https?:/i.test(n.url)) window.open(n.url, "_blank", "noopener");
                    }}
                  >
                    <rect x={n.x} y={n.y} width={n.width} height={n.height} rx={10} fill="#232428" stroke={color(n.color) ?? "#3a3b40"} strokeWidth={2} />
                    <foreignObject x={n.x + 8} y={n.y + 6} width={Math.max(0, n.width - 16)} height={Math.max(0, n.height - 12)}>
                      <div className={styles.nodeText}>{n.type === "text" ? n.text : n.type === "file" ? n.file : n.url}</div>
                    </foreignObject>
                  </g>
                );
              })}
          </g>
        </svg>
      </div>
    </div>
  );
}
