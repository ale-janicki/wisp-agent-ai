import "./assetPath.js";
import React, { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Excalidraw,
  MainMenu,
  exportToBlob,
  exportToSvg,
  serializeAsJSON,
  viewportCoordsToSceneCoords,
} from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";

const CHANGE_DEBOUNCE_MS = 450;
const CLICK_SLOP_PX = 4;
const WIKILINK = /\[\[([^\]\n]+)\]\]/;

function post(message) {
  window.webkit.messageHandlers.wisp.postMessage(JSON.stringify(message));
}

function fingerprint(elements, appState, files) {
  const parts = elements.map((element) => `${element.id}:${element.version}`);
  parts.push(`bg:${appState.viewBackgroundColor}`);
  parts.push(`files:${Object.keys(files || {}).sort().join(",")}`);
  return parts.join("|");
}

function firstLinkIn(element) {
  if (element.link) return element.link;
  if (element.type === "text") {
    const match = WIKILINK.exec(element.text || "");
    if (match) return `[[${match[1]}]]`;
  }
  return null;
}

function App() {
  const apiRef = useRef(null);
  const sourceRef = useRef(null);
  const baselineRef = useRef(null);
  const timerRef = useRef(null);
  const dirtyRef = useRef(false);
  const pendingRef = useRef(false);
  const cleanRef = useRef(null);
  const viewModeRef = useRef(true);
  const pointerRef = useRef(null);
  const [session, setSession] = useState(null);
  const [viewMode, setViewMode] = useState(true);
  const [dark, setDark] = useState(true);

  viewModeRef.current = viewMode;

  const buildScene = useCallback(() => {
    const api = apiRef.current;
    if (!api) return null;
    const elements = api.getSceneElements();
    const appState = api.getAppState();
    const referenced = new Set(
      elements.filter((element) => element.type === "image" && element.fileId).map((element) => element.fileId),
    );
    const allFiles = api.getFiles();
    const files = {};
    for (const id of referenced) if (allFiles[id]) files[id] = allFiles[id];
    const scene = JSON.parse(serializeAsJSON(elements, appState, files, "local"));
    if (sourceRef.current) scene.source = sourceRef.current;
    scene.files = files;
    return JSON.stringify(scene);
  }, []);

  const sendChanged = useCallback(() => {
    const scene = buildScene();
    dirtyRef.current = false;
    pendingRef.current = false;
    if (scene) post({ type: "changed", scene });
  }, [buildScene]);

  const markDirty = useCallback(() => {
    if (dirtyRef.current) return;
    dirtyRef.current = true;
    post({ type: "dirty" });
  }, []);

  const onChange = useCallback(
    (elements, appState, files) => {
      const next = fingerprint(elements, appState, files);
      if (baselineRef.current === null) {
        baselineRef.current = next;
        return;
      }
      if (next === baselineRef.current) return;
      baselineRef.current = next;
      if (viewModeRef.current) return;
      markDirty();
      pendingRef.current = true;
      clearTimeout(timerRef.current);
      timerRef.current = setTimeout(sendChanged, CHANGE_DEBOUNCE_MS);
    },
    [sendChanged, markDirty],
  );

  const exportScene = useCallback(async (format) => {
    const api = apiRef.current;
    if (!api) return;
    try {
      const elements = api.getSceneElements();
      const appState = { ...api.getAppState(), exportBackground: true, exportWithDarkMode: false };
      const files = api.getFiles();
      if (format === "svg") {
        const svg = await exportToSvg({ elements, appState, files, exportPadding: 10 });
        post({ type: "exported", format, data: new XMLSerializer().serializeToString(svg) });
      } else {
        const blob = await exportToBlob({ elements, appState, files, mimeType: "image/png", exportPadding: 10 });
        const bytes = new Uint8Array(await blob.arrayBuffer());
        let binary = "";
        for (let index = 0; index < bytes.length; index += 0x8000) {
          binary += String.fromCharCode.apply(null, bytes.subarray(index, index + 0x8000));
        }
        post({ type: "exported", format, data: btoa(binary) });
      }
    } catch (error) {
      post({ type: "failure", message: `exportação falhou: ${error && error.message ? error.message : error}` });
    }
  }, []);

  useEffect(() => {
    window.wispBridge = {
      receive(message) {
        switch (message.type) {
          case "load": {
            clearTimeout(timerRef.current);
            dirtyRef.current = false;
            const previous = apiRef.current ? apiRef.current.getAppState() : null;
            const scene = JSON.parse(message.scene);
            sourceRef.current = scene.source || null;
            baselineRef.current = null;
            const appState = { ...(scene.appState || {}) };
            delete appState.collaborators;
            setViewMode(message.viewMode);
            setDark(message.dark);
            setSession({
              id: Date.now(),
              language: message.language,
              initialData: {
                elements: scene.elements || [],
                appState: {
                  ...appState,
                  ...(previous ? { scrollX: previous.scrollX, scrollY: previous.scrollY, zoom: previous.zoom } : {}),
                  viewModeEnabled: message.viewMode,
                },
                files: message.files || {},
                scrollToContent: !previous,
              },
            });
            break;
          }
          case "setViewMode":
            setViewMode(message.viewMode);
            if (apiRef.current) apiRef.current.updateScene({ appState: { viewModeEnabled: message.viewMode } });
            break;
          case "setTheme":
            setDark(message.dark);
            break;
          case "requestSave": {
            clearTimeout(timerRef.current);
            const scene = buildScene();
            dirtyRef.current = false;
            pendingRef.current = false;
            if (scene) post({ type: "save", scene });
            break;
          }
          case "export":
            exportScene(message.format);
            break;
          default:
            break;
        }
      },
    };
    post({ type: "ready" });
    return () => {
      delete window.wispBridge;
    };
  }, [buildScene, exportScene]);

  useEffect(() => {
    const onKeyDown = (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault();
        clearTimeout(timerRef.current);
        const scene = buildScene();
        dirtyRef.current = false;
        pendingRef.current = false;
        if (scene && !viewModeRef.current) post({ type: "save", scene });
      }
    };
    const onPointerDown = (event) => {
      pointerRef.current = { x: event.clientX, y: event.clientY, modifier: event.metaKey || event.ctrlKey };
    };
    const onPointerUp = (event) => {
      const down = pointerRef.current;
      pointerRef.current = null;
      const api = apiRef.current;
      if (!down || !api || event.button !== 0) return;
      if (Math.hypot(event.clientX - down.x, event.clientY - down.y) > CLICK_SLOP_PX) return;
      if (!viewModeRef.current && !down.modifier) return;
      const appState = api.getAppState();
      const point = viewportCoordsToSceneCoords({ clientX: event.clientX, clientY: event.clientY }, appState);
      const elements = api.getSceneElements();
      for (let index = elements.length - 1; index >= 0; index -= 1) {
        const element = elements[index];
        const link = firstLinkIn(element);
        if (!link || !WIKILINK.test(link)) continue;
        const left = Math.min(element.x, element.x + element.width);
        const top = Math.min(element.y, element.y + element.height);
        if (point.x >= left && point.x <= left + Math.abs(element.width) && point.y >= top && point.y <= top + Math.abs(element.height)) {
          post({ type: "openLink", link });
          return;
        }
      }
    };
    const onInput = () => {
      if (viewModeRef.current) return;
      markDirty();
      clearTimeout(cleanRef.current);
      cleanRef.current = setTimeout(() => {
        if (pendingRef.current || !dirtyRef.current) return;
        dirtyRef.current = false;
        post({ type: "clean" });
      }, 2000);
    };
    window.addEventListener("input", onInput, true);
    window.addEventListener("keydown", onKeyDown, true);
    window.addEventListener("pointerdown", onPointerDown, true);
    window.addEventListener("pointerup", onPointerUp, true);
    return () => {
      window.removeEventListener("input", onInput, true);
      window.removeEventListener("keydown", onKeyDown, true);
      window.removeEventListener("pointerdown", onPointerDown, true);
      window.removeEventListener("pointerup", onPointerUp, true);
    };
  }, [buildScene, markDirty]);

  if (!session) return null;

  return (
    <Excalidraw
      key={session.id}
      excalidrawAPI={(api) => {
        apiRef.current = api;
      }}
      initialData={session.initialData}
      onChange={onChange}
      viewModeEnabled={viewMode}
      theme={dark ? "dark" : "light"}
      langCode={session.language || "pt-BR"}
      handleKeyboardGlobally
      autoFocus
      onLinkOpen={(element, event) => {
        event.preventDefault();
        if (element.link) post({ type: "openLink", link: element.link });
      }}
      UIOptions={{
        canvasActions: {
          loadScene: false,
          saveToActiveFile: false,
          saveAsImage: false,
          export: false,
          toggleTheme: false,
        },
      }}
    >
      <MainMenu>
        <MainMenu.DefaultItems.ClearCanvas />
        <MainMenu.DefaultItems.ChangeCanvasBackground />
        <MainMenu.DefaultItems.Help />
      </MainMenu>
    </Excalidraw>
  );
}

window.addEventListener("error", (event) => post({ type: "failure", message: String(event.message) }));
window.addEventListener("unhandledrejection", (event) => post({ type: "failure", message: String(event.reason) }));

createRoot(document.getElementById("root")).render(<App />);
