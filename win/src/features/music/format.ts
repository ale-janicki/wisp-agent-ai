const pad = (n: number) => String(n).padStart(2, "0");

export function duration(ms: number): string {
  const total = Math.floor(Math.max(0, ms) / 1000);
  return `${Math.floor(total / 60)}:${pad(total % 60)}`;
}

export const clock = (seconds: number) => duration(Math.floor(Math.max(0, seconds)) * 1000);

export function count(tracks: number | null | undefined): string {
  if (tracks === null || tracks === undefined) return "Playlist";
  return tracks === 1 ? "1 música" : `${tracks} músicas`;
}
