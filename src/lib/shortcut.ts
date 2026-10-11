// Converts between key events, the accelerator strings the Rust side registers, and
// what the user sees (⇧⌘9 on macOS, Ctrl+Shift+9 on Windows).

const KEY_NAMES: Record<string, string> = {
  Space: "Space", Comma: ",", Period: ".", Slash: "/", Semicolon: ";", Quote: "'",
  BracketLeft: "[", BracketRight: "]", Minus: "-", Equal: "=", Backquote: "`", Backslash: "\\",
};

export interface KeyLike {
  code: string;
  metaKey: boolean;
  ctrlKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
}

/** Returns null unless the combination has Command/Control/Alt and a usable key. */
export function acceleratorFromEvent(event: KeyLike, mac: boolean): string | null {
  const key = keyFromCode(event.code);
  if (!key) return null;
  const parts: string[] = [];
  if (mac) {
    if (event.ctrlKey) parts.push("Control");
    if (event.altKey) parts.push("Alt");
    if (event.shiftKey) parts.push("Shift");
    if (event.metaKey) parts.push("CommandOrControl");
  } else {
    if (event.ctrlKey) parts.push("CommandOrControl");
    if (event.altKey) parts.push("Alt");
    if (event.shiftKey) parts.push("Shift");
    if (event.metaKey) parts.push("Super");
  }
  if (!parts.some((p) => p === "CommandOrControl" || p === "Control" || p === "Alt")) return null;
  return [...parts, key].join("+");
}

function keyFromCode(code: string): string | null {
  if (/^Digit\d$/.test(code)) return code.slice(5);
  if (/^Key[A-Z]$/.test(code)) return code.slice(3);
  if (/^F\d{1,2}$/.test(code)) return code;
  return code in KEY_NAMES ? code : null;
}

export function displayAccelerator(accelerator: string, mac: boolean): string {
  const parts = accelerator.split("+");
  const key = parts.pop() ?? "";
  const shown = KEY_NAMES[key] ?? key.replace(/^Digit/, "").replace(/^Key/, "");
  if (!mac) {
    const names: Record<string, string> = { CommandOrControl: "Ctrl", Control: "Ctrl", Alt: "Alt", Shift: "Shift", Super: "Win" };
    return [...parts.map((p) => names[p] ?? p), shown].join("+");
  }
  const order = ["Control", "Alt", "Shift", "CommandOrControl"];
  const symbols: Record<string, string> = { Control: "⌃", Alt: "⌥", Shift: "⇧", CommandOrControl: "⌘", Command: "⌘", Super: "⌘" };
  const sorted = [...parts].sort((a, b) => order.indexOf(a) - order.indexOf(b));
  return sorted.map((p) => symbols[p] ?? p).join("") + shown;
}
