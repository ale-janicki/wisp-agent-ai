import { cpSync, rmSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const here = dirname(fileURLToPath(import.meta.url));
const fonts = resolve(here, "node_modules/@excalidraw/excalidraw/dist/prod/fonts");
const skippedFontFamilies = ["Xiaolai"];

const copyFonts = () => ({
  name: "wisp-copy-excalidraw-fonts",
  closeBundle() {
    const target = resolve(here, "../../Resources/Excalidraw/fonts");
    cpSync(fonts, target, { recursive: true });
    for (const family of skippedFontFamilies) rmSync(resolve(target, family), { recursive: true, force: true });
  },
});

export default defineConfig({
  base: "/",
  plugins: [react(), copyFonts()],
  define: { "process.env.NODE_ENV": JSON.stringify("production") },
  build: {
    outDir: resolve(here, "../../Resources/Excalidraw"),
    emptyOutDir: true,
    sourcemap: false,
    chunkSizeWarningLimit: 6000,
  },
});
