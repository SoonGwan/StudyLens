// Typed bridge to the Rust core. Windows render snapshots pushed as events.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useState } from "react";

export type Status = "idle" | "selecting" | "analyzing" | "ready" | "failed";
export type Hint = "accessibility" | "screenRecording" | "chatGptUsage" | "claudeUsage" | "settings";
export type BillingMode = "claudeCode" | "chatGpt" | "apiKey";

export interface Block {
  id: number;
  text: string;
  language: string | null;
  isComplete: boolean;
}

export interface ResultState {
  status: Status;
  explanation: string;
  blocks: Block[];
  capturedImage: string | null;
  selectedText: string;
  errorMessage: string | null;
  hint: Hint | null;
  copied: boolean;
  copiedCodeId: number | null;
  quickCopyMessage: string | null;
  billingLabel: string;
}

export interface Shortcuts {
  capture: string;
  text: string;
  code: string;
}

export interface Settings {
  billingMode: BillingMode;
  shortcuts: Shortcuts;
  codeLanguage: string;
  apiModel: string;
  chatgptModel: string;
  claudeModel: string;
  claudePath: string;
  hostId: string;
  onboarded: boolean;
}

export interface ClaudeStatus {
  loggedIn: boolean;
  authMethod?: string | null;
  email?: string | null;
  subscriptionType?: string | null;
}

export interface SettingsView {
  settings: Settings;
  hasApiKey: boolean;
  chatgptProfiles: { clientId: string; label: string; connected: boolean; permitsInference: boolean }[];
  activeClientId: string | null;
  connection: {
    busy: boolean;
    message: string | null;
    chatgptModels: { slug: string; displayName: string }[];
    claudeStatus: ClaudeStatus | null;
  };
  shortcutErrors: string[];
  codeLanguages: string[];
  claudeModels: [string, string][];
  platform: "macos" | "windows";
  working: boolean;
}

export const api = {
  getResult: () => invoke<ResultState>("get_result"),
  getSettings: () => invoke<SettingsView>("get_settings"),
  start: (action: "capture" | "text" | "code") => invoke("start", { action }),
  copyExplanation: () => invoke("copy_explanation"),
  copyCode: (id: number) => invoke("copy_code", { id }),
  saveSettings: (settings: Settings) => invoke("save_settings", { settings }),
  saveApiKey: (key: string) => invoke("save_api_key", { key }),
  chatgptSignIn: (newAccount = false, requestConsent = false) => invoke("chatgpt_sign_in", { newAccount, requestConsent }),
  chatgptCancel: () => invoke("chatgpt_cancel"),
  chatgptSelect: (clientId: string) => invoke("chatgpt_select", { clientId }),
  chatgptRefreshModels: () => invoke("chatgpt_refresh_models"),
  chatgptSignOut: () => invoke("chatgpt_sign_out"),
  claudeRefreshStatus: () => invoke("claude_refresh_status"),
  claudeSignIn: () => invoke("claude_sign_in"),
  claudeCancel: () => invoke("claude_cancel"),
  openLink: (url: string) => invoke("open_link", { url }),
  openPrivacySettings: (kind: "screen" | "accessibility") => invoke("open_privacy_settings", { kind }),
  openSettings: () => invoke("open_settings"),
  hideWindow: () => invoke("hide_window"),
  overlayImage: () => invoke<string | null>("overlay_image"),
  overlayFinish: (rect: { x: number; y: number; width: number; height: number } | null) => invoke("overlay_finish", { rect }),
};

/** Subscribes to a state snapshot: initial fetch, then every pushed update. */
function useSnapshot<T>(event: string, load: () => Promise<T>): T | null {
  const [value, setValue] = useState<T | null>(null);
  useEffect(() => {
    let active = true;
    load().then((v) => active && setValue(v));
    const unlisten = listen<T>(event, (e) => setValue(e.payload));
    return () => {
      active = false;
      unlisten.then((stop) => stop());
    };
  }, [event, load]);
  return value;
}

export const useResult = () => useSnapshot("result", api.getResult);
export const useSettingsView = () => useSnapshot("settings", api.getSettings);

export const isMac = navigator.userAgent.includes("Mac");
