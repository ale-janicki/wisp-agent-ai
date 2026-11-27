import { useEffect, type ReactNode } from "react";
import type { SidecarInfo } from "./api/types";
import { useChat, type ChatDeps } from "./state/useChat";

type Session = ReturnType<typeof useChat>;

type Props = {
  info: SidecarInfo;
  deps?: ChatDeps;
  onSummary: (s: { pendingPermission: boolean; thinking: boolean }) => void;
  children: (session: Session) => ReactNode;
};

export function WispSession({ info, deps, onSummary, children }: Props) {
  const session = useChat(info, deps);
  const { state } = session;
  const pendingPermission = state.permissions.length > 0;
  const thinking = Object.values(state.status).includes("thinking");

  useEffect(() => {
    onSummary({ pendingPermission, thinking });
  }, [pendingPermission, thinking, onSummary]);

  return <>{children(session)}</>;
}
