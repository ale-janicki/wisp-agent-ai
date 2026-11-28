export type Profile = { user: string | null; first_name: string | null; persona: string; language: string };

export type LimitRow =
  | { kind: "session" | "week"; state: "used"; percent: number; resets_at: number | null; severity: "normal" | "warning" | "critical" }
  | { kind: "session" | "week"; state: "renewed" };

export type Usage = {
  limits: { captured_at: number; rows: LimitRow[] } | null;
  tokens: { today: number; week: number } | null;
};

export type ConversationItem = { id: string; title: string; updated_at: string; preview: string | null; telegram: boolean; engine: string };
