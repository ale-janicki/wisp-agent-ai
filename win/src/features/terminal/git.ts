export type GitStatus = { branch: string; changedFiles: number; insertions: number; deletions: number };

function branchName(porcelain: string): string | null {
  let head: string | null = null;
  let oid: string | null = null;
  for (const line of porcelain.split("\n")) {
    if (line.startsWith("# branch.head ")) head = line.slice("# branch.head ".length).trim();
    if (line.startsWith("# branch.oid ")) oid = line.slice("# branch.oid ".length).trim();
  }
  if (head === null) return null;
  if (head !== "(detached)") return head;
  if (oid === null || oid === "(initial)") return null;
  return oid.slice(0, 7);
}

const changedCount = (porcelain: string): number =>
  porcelain.split("\n").filter((line) => line.length > 1 && line[1] === " " && "12u?".includes(line[0]!)).length;

function parseShortstat(text: string): { insertions: number; deletions: number } {
  let insertions = 0;
  let deletions = 0;
  for (const part of text.split(",")) {
    const words = part.trim().split(/\s+/);
    const value = Number.parseInt(words[0] ?? "", 10);
    if (!Number.isFinite(value) || words.length < 2) continue;
    if (words[1]!.startsWith("insertion")) insertions = value;
    if (words[1]!.startsWith("deletion")) deletions = value;
  }
  return { insertions, deletions };
}

export function parseGitStatus(porcelain: string, shortstat: string): GitStatus | null {
  const branch = branchName(porcelain);
  if (branch === null) return null;
  return { branch, changedFiles: changedCount(porcelain), ...parseShortstat(shortstat) };
}

export const isDefaultBranch = (branch: string): boolean => branch === "main" || branch === "master";
