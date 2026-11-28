export type GridReason = "alternateScreen" | "mouseTracking" | "allowlisted" | "plainShell" | "manual";
export type PaneMode = { kind: "blocks" } | { kind: "grid"; reason: GridReason };

export const DEFAULT_ALLOWLIST: ReadonlySet<string> = new Set([
  "claude", "ssh", "mosh", "docker", "kubectl", "tmux", "python", "python3", "node", "irb", "ipython",
  "top", "htop", "btop", "less", "more", "man", "nano", "vim", "nvim", "vi", "emacs",
  "wsl", "pwsh", "powershell", "cmd", "bash", "zsh", "fish", "psql", "mysql", "sqlite3", "redis-cli",
]);

const WRAPPERS = new Set(["sudo", "exec", "command"]);
const REPL_NAMES = new Set(["python", "python3", "ipython", "node", "irb"]);
const NOT_REPL_FLAGS = new Set(["-c", "-m", "-e", "-p", "-V", "--version", "-h", "--help", "--eval", "--print", "--check"]);
const SUDO_VALUE_OPTIONS = new Set(["-u", "-g", "-h", "-p", "-C", "-U", "-r", "-t", "-D", "--user", "--group", "--host", "--prompt", "--close-from", "--other-user", "--role", "--type", "--chdir"]);
const INFORMATION_FLAGS = new Set(["--version", "-V", "--help", "-h", "-v"]);
const INTERACTIVE_SOLE_FLAGS: Record<string, Set<string>> = {
  vim: new Set(["-v", "-V"]), nvim: new Set(["-v", "-V"]), vi: new Set(["-v", "-V"]),
  ssh: new Set(["-v"]), tmux: new Set(["-v"]),
  less: new Set(["-h", "--help"]), more: new Set(["-h", "--help"]),
};
const SSH_VALUE_OPTIONS = new Set("bcDEeFIiJLlmOopQRSWw");
const MAN_LOOKUP_FLAGS = new Set(["-k", "-f", "-w", "--apropos", "--whatis", "--where", "--path"]);
const TMUX_SESSION_COMMANDS = new Set(["attach", "attach-session", "a", "at", "new", "new-session", "n", "new-s"]);

export function decidePaneMode(input: { altScreen: boolean; mouse: boolean; command: string | null; allowlist: ReadonlySet<string> }): PaneMode {
  if (input.altScreen) return { kind: "grid", reason: "alternateScreen" };
  if (input.mouse) return { kind: "grid", reason: "mouseTracking" };
  if (input.command !== null && isInteractive(input.command, input.allowlist)) return { kind: "grid", reason: "allowlisted" };
  return { kind: "blocks" };
}

type Segment = { text: string; pipedOut: boolean };

function segmentsOf(command: string): Segment[] {
  const result: Segment[] = [];
  let current = "";
  let quote: string | null = null;
  let escaped = false;
  const chars = Array.from(command);
  let index = 0;
  while (index < chars.length) {
    const char = chars[index]!;
    index += 1;
    if (escaped) {
      escaped = false;
    } else if (quote !== null) {
      if (char === quote) quote = null;
      else if (char === "`" && quote === '"') escaped = true;
    } else if (char === "`") {
      escaped = true;
    } else if (char === "'" || char === '"') {
      quote = char;
    } else if (char === ";" || char === "&" || char === "|" || char === "\n") {
      const doubled = (char === "&" || char === "|") && chars[index] === char;
      if (doubled) index += 1;
      result.push({ text: current, pipedOut: char === "|" && !doubled });
      current = "";
      continue;
    }
    current += char;
  }
  result.push({ text: current, pipedOut: false });
  return result;
}

const isAssignment = (word: string): boolean => /^[A-Za-z_][A-Za-z0-9_]*=/.test(word);

export function isInteractive(command: string, allowlist: ReadonlySet<string>): boolean {
  return segmentsOf(command).some((segment) => !segment.pipedOut && segmentIsInteractive(segment.text, allowlist));
}

function segmentIsInteractive(segment: string, allowlist: ReadonlySet<string>): boolean {
  const words = segment.split(/\s+/).filter((w) => w !== "");
  while (words.length > 0 && isAssignment(words[0]!)) words.shift();
  while (words.length > 0 && WRAPPERS.has(words[0]!)) {
    const wrapper = words.shift()!;
    while (words.length > 0 && words[0]!.startsWith("-")) {
      const flag = words.shift()!;
      if (wrapper === "sudo") {
        if (flag === "--") break;
        if (SUDO_VALUE_OPTIONS.has(flag) && words.length > 0) words.shift();
      }
    }
    while (words.length > 0 && isAssignment(words[0]!)) words.shift();
  }
  const first = words[0];
  if (first === undefined) return false;
  const name = (first.split(/[\\/]/).pop() ?? first).replace(/\.(exe|cmd|bat|com)$/i, "").toLowerCase();
  if (!allowlist.has(name)) return false;
  const args = words.slice(1);
  if (isNonInteractiveInvocation(name, args)) return false;
  switch (name) {
    case "docker": return runsInteractively(args, new Set(["run", "exec"]));
    case "kubectl": return runsInteractively(args, new Set(["exec"]));
    case "ssh": return opensRemoteShell(args);
    case "tmux": return opensTmuxSession(args);
    case "top": return !args.some((a, i) => a === "-l" && i + 1 < args.length);
    case "man": return !args.some((a) => MAN_LOOKUP_FLAGS.has(a));
    default:
      if (REPL_NAMES.has(name)) return !args.some((a) => !a.startsWith("-") || NOT_REPL_FLAGS.has(a));
      return true;
  }
}

function isNonInteractiveInvocation(name: string, args: string[]): boolean {
  if (args.length === 1 && INFORMATION_FLAGS.has(args[0]!) && !INTERACTIVE_SOLE_FLAGS[name]?.has(args[0]!)) return true;
  if (name === "claude") return args.some((a) => a === "-p" || a === "--print");
  if (name === "emacs") return args.some((a) => a === "--batch" || a === "-batch");
  return false;
}

function opensRemoteShell(args: string[]): boolean {
  let positional = 0;
  let index = 0;
  while (index < args.length) {
    const arg = args[index]!;
    index += 1;
    if (arg === "--") {
      positional += args.length - index;
      break;
    }
    if (arg.startsWith("-") && arg.length > 1) {
      if (arg.length === 2 && SSH_VALUE_OPTIONS.has(arg[1]!)) index += 1;
    } else {
      positional += 1;
    }
  }
  return positional <= 1;
}

function opensTmuxSession(args: string[]): boolean {
  let index = 0;
  while (index < args.length && args[index]!.startsWith("-")) {
    index += 1;
    if (["-L", "-S", "-f", "-c", "-T"].includes(args[index - 1]!)) index += 1;
  }
  if (index >= args.length) return true;
  const sub = args[index]!;
  if (!TMUX_SESSION_COMMANDS.has(sub)) return false;
  return !(sub.startsWith("n") && args.slice(index + 1).some((a) => a.startsWith("-") && !a.startsWith("--") && a.includes("d")));
}

function runsInteractively(args: string[], subcommands: Set<string>): boolean {
  const sub = args.find((a) => !a.startsWith("-"));
  if (sub === undefined || !subcommands.has(sub)) return false;
  let interactive = false;
  let tty = false;
  for (const arg of args) {
    if (arg === "--") break;
    if (arg === "--interactive") interactive = true;
    if (arg === "--tty" || arg === "--tty=true") tty = true;
    if (arg.startsWith("-") && !arg.startsWith("--") && /^-[A-Za-z]+$/.test(arg)) {
      if (arg.includes("i")) interactive = true;
      if (arg.includes("t")) tty = true;
    }
  }
  return interactive && tty;
}
