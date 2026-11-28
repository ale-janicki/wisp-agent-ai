import { useSyncExternalStore } from "react";
import type { TerminalSession } from "./session";
import type { TerminalWorkspace } from "./workspace";

export function useSession(session: TerminalSession): number {
  return useSyncExternalStore(session.subscribe, session.getVersion);
}

export function useWorkspace(workspace: TerminalWorkspace<TerminalSession>): number {
  return useSyncExternalStore(workspace.subscribe, workspace.getVersion);
}
