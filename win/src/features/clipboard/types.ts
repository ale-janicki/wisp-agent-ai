export type ClipItem = {
  id: string;
  kind: "text" | "url" | "image";
  text: string | null;
  image: string | null;
  copied_at: number;
  pinned: boolean;
};

export type ItemsResponse = {
  items: ClipItem[];
  capture: boolean;
  notice: string | null;
  empty: string | null;
  available: boolean;
};
