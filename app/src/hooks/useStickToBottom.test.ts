import { describe, expect, it } from "vitest";
import { STICK_SLACK_PX, isNearBottom } from "./useStickToBottom";

describe("isNearBottom", () => {
  // A pane 200px tall showing content 1000px tall: the end is scrollTop 800.

  it("is true at the very end", () => {
    expect(isNearBottom(800, 200, 1000)).toBe(true);
  });

  it("is true within the slack, so a half-visible last line still counts", () => {
    expect(isNearBottom(800 - STICK_SLACK_PX, 200, 1000)).toBe(true);
  });

  it("is false once the reader has scrolled further up than the slack", () => {
    expect(isNearBottom(800 - STICK_SLACK_PX - 1, 200, 1000)).toBe(false);
    expect(isNearBottom(0, 200, 1000)).toBe(false);
  });

  it("is true for content that does not fill the pane", () => {
    expect(isNearBottom(0, 200, 120)).toBe(true);
  });

  it("tolerates a fractional scroll position (display scaling)", () => {
    expect(isNearBottom(799.4, 200, 1000)).toBe(true);
  });
});
