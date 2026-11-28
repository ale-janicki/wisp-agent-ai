import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Pill, type PillTone } from "./components/Pill";
import { PanelShell } from "./shell/PanelShell";
import { listenShell, quit, readSidecar, setMode, type ShellMode, type SidecarState } from "./shell/bridge";
import type { ChatDeps } from "./state/useChat";
import { WispSession } from "./WispSession";

const HOVER_OPEN_MS = 300;
const LEAVE_COLLAPSE_MS = 600;

export function App({ deps }: { deps?: ChatDeps }) {
  const [sidecar, setSidecar] = useState<SidecarState>({ status: "preparing" });
  const [mode, setModeState] = useState<ShellMode>("pill");
  const [focusComposer, setFocusComposer] = useState(false);
  const [draft, setDraft] = useState("");
  const [pendingPermission, setPendingPermission] = useState(false);
  const [thinking, setThinking] = useState(false);

  const open = useRef<ReturnType<typeof setTimeout> | null>(null);
  const close = useRef<ReturnType<typeof setTimeout> | null>(null);
  const modeRef = useRef(mode);
  modeRef.current = mode;
  const blockedRef = useRef(false);
  blockedRef.current = draft.trim() !== "" || pendingPermission;

  const onSummary = useCallback((s: { pendingPermission: boolean; thinking: boolean }) => {
    setPendingPermission(s.pendingPermission);
    setThinking(s.thinking);
  }, []);

  const clearTimers = () => {
    if (open.current) clearTimeout(open.current);
    if (close.current) clearTimeout(close.current);
    open.current = close.current = null;
  };

  const show = useCallback((next: ShellMode, byHover: boolean) => {
    clearTimers();
    setFocusComposer(next === "panel" && !byHover);
    setModeState(next);
    void setMode(next, next !== "pill" && !byHover);
  }, []);

  useEffect(() => {
    let off: (() => void) | undefined;
    let gone = false;
    void listenShell({
      onClose: () => modeRef.current === "window" && show("pill", false),
      onSidecar: setSidecar,
      onToggle: () => show(modeRef.current === "panel" ? "pill" : "panel", false),
      onOpen: () => show("panel", false),
    }).then((fn) => (gone ? fn() : (off = fn)), () => {});
    readSidecar().then(setSidecar, (e) => setSidecar({ status: "failed", message: String(e) }));
    return () => {
      gone = true;
      off?.();
    };
  }, [show]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && modeRef.current === "panel") show("pill", false);
    };
    const onBlur = () => {
      if (modeRef.current === "panel" && !pendingPermission) show("pill", false);
    };
    document.addEventListener("keydown", onKey);
    window.addEventListener("blur", onBlur);
    return () => {
      document.removeEventListener("keydown", onKey);
      window.removeEventListener("blur", onBlur);
    };
  }, [show, pendingPermission]);

  const pillEnter = () => {
    clearTimers();
    open.current = setTimeout(() => show("panel", true), HOVER_OPEN_MS);
  };
  const pillLeave = () => clearTimers();
  const panelEnter = () => {
    if (close.current) clearTimeout(close.current);
    close.current = null;
  };
  const panelLeave = () => {
    if (modeRef.current === "window") return;
    const typing = document.activeElement instanceof HTMLTextAreaElement;
    if (blockedRef.current || typing) return;
    close.current = setTimeout(() => show("pill", false), LEAVE_COLLAPSE_MS);
  };

  const info = useMemo(
    () => (sidecar.status === "ready" ? { port: sidecar.port, token: sidecar.token } : null),
    [sidecar],
  );

  if (sidecar.status !== "ready" || !info) {
    const failed = sidecar.status === "failed";
    return (
      <Pill
        label={failed ? sidecar.message : "Preparando o Wisp…"}
        tone={failed ? "error" : "busy"}
        onMouseEnter={() => {}}
        onMouseLeave={() => {}}
        onClick={() => {
          if (failed) void quit();
        }}
      />
    );
  }

  const chatStatus = (s: { error: string | null }, busy: boolean) =>
    s.error ? ({ label: "Erro", tone: "error" } as const) : busy ? ({ label: "Pensando…", tone: "busy" } as const) : ({ label: "Pronto", tone: "ok" } as const);

  const tone: PillTone = pendingPermission ? "attention" : thinking ? "busy" : "idle";
  const label = pendingPermission ? "Esperando tua aprovação" : thinking ? "Pensando…" : "Wisp";

  return (
    <WispSession
      info={info}
      deps={deps}
      onSummary={onSummary}
    >
      {(session, bus) =>
        mode !== "pill" ? (
          <PanelShell
            value={{
              info,
              bus,
              fetchImpl: deps?.fetchImpl,
              session,
              draft,
              setDraft,
              focusComposer,
            }}
            windowed={mode === "window"}
            onToggleWindow={() => show(mode === "window" ? "panel" : "window", false)}
            status={chatStatus(session.state, thinking)}
            onMouseEnter={panelEnter}
            onMouseLeave={panelLeave}
          />
        ) : (
          <Pill label={label} tone={tone} onMouseEnter={pillEnter} onMouseLeave={pillLeave} onClick={() => show("panel", false)} />
        )
      }
    </WispSession>
  );
}
