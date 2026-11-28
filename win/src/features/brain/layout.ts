export type LNode = { id: string; x: number; y: number; vx: number; vy: number; degree: number };

const GOLDEN = Math.PI * (3 - Math.sqrt(5));
const LINK_DISTANCE = 44;
const REPULSION = 900;
const CELL = 90;
const DECAY = 0.6;

export function initLayout(ids: string[], degrees: Record<string, number>, seeds: Record<string, { x: number; y: number }> = {}): LNode[] {
  return ids.map((id, i) => {
    const seed = seeds[id];
    const radius = 12 * Math.sqrt(i + 0.5);
    return {
      id,
      x: seed?.x ?? radius * Math.cos(i * GOLDEN),
      y: seed?.y ?? radius * Math.sin(i * GOLDEN),
      vx: 0,
      vy: 0,
      degree: degrees[id] ?? 0,
    };
  });
}

export function step(nodes: LNode[], edges: [number, number][], alpha: number): void {
  const grid = new Map<string, number[]>();
  nodes.forEach((n, i) => {
    const key = `${Math.floor(n.x / CELL)},${Math.floor(n.y / CELL)}`;
    const cell = grid.get(key);
    if (cell) cell.push(i);
    else grid.set(key, [i]);
  });
  nodes.forEach((a, i) => {
    const cx = Math.floor(a.x / CELL);
    const cy = Math.floor(a.y / CELL);
    for (let dx = -1; dx <= 1; dx++)
      for (let dy = -1; dy <= 1; dy++)
        for (const j of grid.get(`${cx + dx},${cy + dy}`) ?? []) {
          if (j <= i) continue;
          const b = nodes[j]!;
          let vx = a.x - b.x;
          let vy = a.y - b.y;
          let d2 = vx * vx + vy * vy;
          if (d2 === 0) {
            vx = (i % 2 ? 1 : -1) * 0.01;
            vy = 0.01;
            d2 = vx * vx + vy * vy;
          }
          const force = (REPULSION * alpha) / d2;
          const d = Math.sqrt(d2);
          a.vx += (vx / d) * force;
          a.vy += (vy / d) * force;
          b.vx -= (vx / d) * force;
          b.vy -= (vy / d) * force;
        }
  });
  for (const [s, t] of edges) {
    const a = nodes[s]!;
    const b = nodes[t]!;
    const vx = b.x - a.x;
    const vy = b.y - a.y;
    const d = Math.hypot(vx, vy) || 0.01;
    const strength = 1 / Math.max(1, Math.min(a.degree, b.degree));
    const pull = ((d - LINK_DISTANCE) / d) * strength * 0.3 * alpha;
    a.vx += vx * pull;
    a.vy += vy * pull;
    b.vx -= vx * pull;
    b.vy -= vy * pull;
  }
  for (const n of nodes) {
    n.vx -= n.x * 0.01 * alpha;
    n.vy -= n.y * 0.01 * alpha;
    n.x += n.vx;
    n.y += n.vy;
    n.vx *= DECAY;
    n.vy *= DECAY;
  }
}

export function settle(nodes: LNode[], edges: [number, number][], steps = 300): void {
  for (let i = 0; i < steps; i++) step(nodes, edges, Math.max(0.02, 1 - i / steps));
}
