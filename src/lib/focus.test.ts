import { describe, expect, it } from "vitest";
import { focusDurationLabel } from "./focus";

describe("Focus duration caption", () => {
  it("shows this morning before dawn", () => {
    expect(focusDurationLabel(0)).toBe("오늘 아침까지");
    expect(focusDurationLabel(5)).toBe("오늘 아침까지");
  });
  it("shows this evening during the day", () => {
    expect(focusDurationLabel(6)).toBe("오늘 저녁까지");
    expect(focusDurationLabel(17)).toBe("오늘 저녁까지");
  });
  it("shows tomorrow morning at night", () => {
    expect(focusDurationLabel(18)).toBe("내일 아침까지");
    expect(focusDurationLabel(23)).toBe("내일 아침까지");
  });
});
