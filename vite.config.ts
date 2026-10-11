import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";

// Tauri serves these pages; each window loads its own entry.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  envPrefix: ["VITE_", "TAURI_ENV_"],
  build: {
    target: "safari16",
    rollupOptions: {
      input: {
        result: resolve(__dirname, "result.html"),
        settings: resolve(__dirname, "settings.html"),
        tray: resolve(__dirname, "tray.html"),
        overlay: resolve(__dirname, "overlay.html"),
      },
    },
  },
});
