import { describe, expect, it } from "vitest";
import { acceleratorFromEvent, displayAccelerator } from "./shortcut";

const key = (code: string, mods: Partial<{ metaKey: boolean; ctrlKey: boolean; altKey: boolean; shiftKey: boolean }> = {}) => ({
  code, metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...mods,
});

describe("shortcut", () => {
  it("records macOS combinations as cross-platform accelerators", () => {
    expect(acceleratorFromEvent(key("Digit9", { metaKey: true, shiftKey: true }), true)).toBe("Shift+CommandOrControl+9");
    expect(acceleratorFromEvent(key("KeyK", { altKey: true }), true)).toBe("Alt+K");
  });

  it("requires Command, Control or Alt", () => {
    expect(acceleratorFromEvent(key("Digit9", { shiftKey: true }), true)).toBeNull();
    expect(acceleratorFromEvent(key("ShiftLeft", { metaKey: true }), true)).toBeNull();
  });

  it("maps Ctrl to CommandOrControl on Windows", () => {
    expect(acceleratorFromEvent(key("Digit8", { ctrlKey: true, shiftKey: true }), false)).toBe("CommandOrControl+Shift+8");
  });

  it("displays symbols in macOS order and words on Windows", () => {
    expect(displayAccelerator("CommandOrControl+Shift+9", true)).toBe("⇧⌘9");
    expect(displayAccelerator("Shift+CommandOrControl+Comma", true)).toBe("⇧⌘,");
    expect(displayAccelerator("CommandOrControl+Shift+9", false)).toBe("Ctrl+Shift+9");
  });
});
