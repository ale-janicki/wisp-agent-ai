export function directoryFromReport(report: string | null | undefined): string | null {
  const text = report?.trim();
  if (!text) return null;
  if (/^[A-Za-z]:[\\/]/.test(text) || text.startsWith("\\\\")) return text.replace(/\//g, "\\");
  if (!text.startsWith("file://")) return null;
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    return null;
  }
  let path: string;
  try {
    path = decodeURIComponent(url.pathname);
  } catch {
    return null;
  }
  if (/^\/[A-Za-z]:\//.test(path) || /^\/[A-Za-z]:$/.test(path)) return path.slice(1).replace(/\//g, "\\");
  if (url.hostname) return `\\\\${url.hostname}${path.replace(/\//g, "\\")}`;
  return null;
}

const SEPARATOR = /[\\/]/;
const sameFolder = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();

export function abbreviateDirectory(path: string, home: string | null | undefined): string {
  if (!home || home.length <= 3) return path;
  if (sameFolder(path, home)) return "~";
  const prefix = home.replace(/[\\/]+$/, "");
  if (path.length > prefix.length && sameFolder(path.slice(0, prefix.length), prefix) && SEPARATOR.test(path[prefix.length]!)) {
    return `~${path.slice(prefix.length)}`;
  }
  return path;
}

export function directoryLabel(path: string, home: string | null | undefined): string {
  const shown = abbreviateDirectory(path, home);
  const parts = shown.split(SEPARATOR).filter((p) => p !== "");
  if (parts.length <= 2) return shown;
  return `${parts[0]}\\…\\${parts[parts.length - 1]}`;
}

export function folderName(path: string, home: string | null | undefined): string {
  if (home && sameFolder(path.replace(/[\\/]+$/, ""), home.replace(/[\\/]+$/, ""))) return "~";
  const parts = path.split(SEPARATOR).filter((p) => p !== "");
  return parts[parts.length - 1] ?? path;
}
