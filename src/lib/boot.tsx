import { StrictMode, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import "../styles/base.css";
import { isMac } from "./ipc";

export function boot(app: ReactNode) {
  document.documentElement.classList.add(isMac ? "mac" : "windows");
  createRoot(document.getElementById("root")!).render(<StrictMode>{app}</StrictMode>);
}
