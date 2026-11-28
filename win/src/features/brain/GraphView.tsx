import { useEffect, useMemo, useRef } from "react";
import { fold } from "./rank";
import { initLayout, step, type LNode } from "./layout";
import type { GraphData } from "./types";
import styles from "./Home.module.css";

const STEPS = 300;
const PER_FRAME = 4;

type Props = { data: GraphData; query: string; onOpen: (path: string) => void };

export function GraphView({ data, query, onOpen }: Props) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const view = useRef({ x: 0, y: 0, k: 1, ticks: 0 });
  const nodes = useRef<LNode[]>([]);
  const queryRef = useRef(query);
  queryRef.current = query;

  const index = useMemo(() => new Map(data.nodes.map((n, i) => [n.id, i])), [data]);
  const links = useMemo(
    () => data.edges.flatMap(([a, b]) => (index.has(a) && index.has(b) ? [[index.get(a)!, index.get(b)!] as [number, number]] : [])),
    [data, index],
  );

  useEffect(() => {
    const element = canvas.current;
    const context = element?.getContext?.("2d");
    if (!element || !context) return;
    const ctx = context;
    const state = view.current;
    state.ticks = 0;
    nodes.current = initLayout(
      data.nodes.map((n) => n.id),
      Object.fromEntries(data.nodes.map((n) => [n.id, n.degree])),
    );
    let frame = 0;
    let hover = -1;

    const fit = () => {
      const list = nodes.current;
      if (list.length === 0) return;
      const xs = list.map((n) => n.x);
      const ys = list.map((n) => n.y);
      const w = Math.max(...xs) - Math.min(...xs) || 1;
      const h = Math.max(...ys) - Math.min(...ys) || 1;
      state.k = Math.min(element.clientWidth / (w + 80), element.clientHeight / (h + 80), 3);
      state.x = element.clientWidth / 2 - ((Math.max(...xs) + Math.min(...xs)) / 2) * state.k;
      state.y = element.clientHeight / 2 - ((Math.max(...ys) + Math.min(...ys)) / 2) * state.k;
    };

    const draw = () => {
      const ratio = window.devicePixelRatio || 1;
      element.width = element.clientWidth * ratio;
      element.height = element.clientHeight * ratio;
      ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
      ctx.clearRect(0, 0, element.clientWidth, element.clientHeight);
      ctx.translate(state.x, state.y);
      ctx.scale(state.k, state.k);
      const needle = fold(queryRef.current.trim());
      const lit = (i: number) => !needle || fold(data.nodes[i]!.title).includes(needle);
      ctx.strokeStyle = "rgba(255,255,255,0.12)";
      ctx.lineWidth = 1 / state.k;
      ctx.beginPath();
      for (const [a, b] of links) {
        const p = nodes.current[a]!;
        const q = nodes.current[b]!;
        ctx.moveTo(p.x, p.y);
        ctx.lineTo(q.x, q.y);
      }
      ctx.stroke();
      nodes.current.forEach((n, i) => {
        ctx.fillStyle = lit(i) ? (needle ? "#c9f08a" : "#a3d65c") : "rgba(154,155,161,0.35)";
        ctx.beginPath();
        ctx.arc(n.x, n.y, 2.5 + Math.sqrt(n.degree) * 1.2, 0, Math.PI * 2);
        ctx.fill();
      });
      if (hover >= 0) {
        const n = nodes.current[hover]!;
        ctx.fillStyle = "#f2f2f3";
        ctx.font = `${12 / state.k}px sans-serif`;
        ctx.fillText(data.nodes[hover]!.title, n.x + 6 / state.k, n.y - 6 / state.k);
      }
    };

    const tick = () => {
      for (let i = 0; i < PER_FRAME && state.ticks < STEPS; i++, state.ticks++) step(nodes.current, links, Math.max(0.02, 1 - state.ticks / STEPS));
      if (state.ticks <= PER_FRAME || state.ticks % 40 === 0 || state.ticks === STEPS) fit();
      draw();
      if (state.ticks < STEPS) frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);

    const at = (event: MouseEvent) => {
      const box = element.getBoundingClientRect();
      const x = (event.clientX - box.left - state.x) / state.k;
      const y = (event.clientY - box.top - state.y) / state.k;
      let best = -1;
      let bestD = (10 / state.k) ** 2;
      nodes.current.forEach((n, i) => {
        const d = (n.x - x) ** 2 + (n.y - y) ** 2;
        if (d < bestD) [best, bestD] = [i, d];
      });
      return best;
    };
    let drag: { x: number; y: number; moved: boolean } | null = null;
    const down = (e: MouseEvent) => (drag = { x: e.clientX, y: e.clientY, moved: false });
    const move = (e: MouseEvent) => {
      if (drag) {
        state.x += e.clientX - drag.x;
        state.y += e.clientY - drag.y;
        drag = { x: e.clientX, y: e.clientY, moved: true };
      }
      hover = at(e);
      if (state.ticks >= STEPS) draw();
    };
    const up = (e: MouseEvent) => {
      const clicked = drag && !drag.moved ? at(e) : -1;
      drag = null;
      if (clicked >= 0) onOpen(data.nodes[clicked]!.id);
    };
    const wheel = (e: WheelEvent) => {
      e.preventDefault();
      const box = element.getBoundingClientRect();
      const factor = e.deltaY < 0 ? 1.15 : 1 / 1.15;
      const px = e.clientX - box.left;
      const py = e.clientY - box.top;
      state.x = px - (px - state.x) * factor;
      state.y = py - (py - state.y) * factor;
      state.k *= factor;
      draw();
    };
    element.addEventListener("mousedown", down);
    element.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
    element.addEventListener("wheel", wheel, { passive: false });
    return () => {
      cancelAnimationFrame(frame);
      element.removeEventListener("mousedown", down);
      element.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
      element.removeEventListener("wheel", wheel);
    };
  }, [data, links, onOpen]);

  useEffect(() => {
    const element = canvas.current;
    if (element && view.current.ticks >= STEPS) element.dispatchEvent(new MouseEvent("mousemove"));
  }, [query]);

  return <canvas ref={canvas} className={styles.graph} aria-label="Grafo das notas" />;
}
