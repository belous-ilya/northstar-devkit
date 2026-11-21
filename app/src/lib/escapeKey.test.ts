import { describe, expect, it } from "vitest";
import { OVERLAY_STACK, claimEscape, overlaysAbove, type OverlayName } from "./escapeKey";

/** A key press that records whether it was marked handled. */
function press(key = "Escape", alreadyHandled = false) {
  const e = {
    key,
    defaultPrevented: alreadyHandled,
    preventDefault() {
      e.defaultPrevented = true;
    },
  };
  return e;
}

/** A page with exactly these overlays open. */
function page(...open: OverlayName[]) {
  const selectors = OVERLAY_STACK.filter((o) => open.includes(o.name)).map((o) => o.selector);
  return {
    querySelector: (query: string) =>
      query
        .split(",")
        .map((s) => s.trim())
        .some((s) => selectors.includes(s as (typeof selectors)[number]))
        ? ({} as Element)
        : null,
  };
}

describe("claimEscape", () => {
  it("lets a surface act when nothing above it is open, and marks the key handled", () => {
    const e = press();
    expect(claimEscape(e, "errorCenter", page("errorCenter"))).toBe(true);
    expect(e.defaultPrevented).toBe(true);
  });

  it("keeps the Error Center open while its own confirm is up", () => {
    // The bug: one Escape cancelled the confirm AND closed the list under it.
    const e = press();
    expect(claimEscape(e, "errorCenter", page("errorCenter", "confirm"))).toBe(false);
    expect(e.defaultPrevented).toBe(false); // left for the confirm
  });

  it("closes only the upper of two dialogs opened over each other", () => {
    const open = page("projectManager", "settings");
    const e = press();
    // Listeners run in the order they were added: the lower one first here.
    expect(claimEscape(e, "projectManager", open)).toBe(false);
    expect(claimEscape(e, "settings", open)).toBe(true);
  });

  it("stops a lower surface that runs AFTER the one that handled the key", () => {
    const open = page("projectManager", "settings");
    const e = press();
    expect(claimEscape(e, "settings", open)).toBe(true);
    // Settings has closed by the time a later listener looks, so only the
    // handled mark still protects what is underneath.
    expect(claimEscape(e, "projectManager", page("projectManager"))).toBe(false);
  });

  it("ignores every other key", () => {
    const e = press("Enter");
    expect(claimEscape(e, "settings", page("settings"))).toBe(false);
    expect(e.defaultPrevented).toBe(false);
  });

  it("ignores a press something else already handled", () => {
    expect(claimEscape(press("Escape", true), "settings", page("settings"))).toBe(false);
  });

  it("is not blocked by overlays below it", () => {
    expect(claimEscape(press(), "settings", page("toolRun", "projectManager", "errorCenter", "settings"))).toBe(true);
  });
});

describe("overlaysAbove", () => {
  it("lists what is drawn above, in the stylesheets' order", () => {
    expect(overlaysAbove("errorCenter")).toBe(
      ".confirm-dialog__overlay, .update-dialog__overlay, .settings-dialog__overlay, .command-palette__overlay",
    );
  });

  it("is empty for the topmost overlay", () => {
    expect(overlaysAbove("palette")).toBe("");
  });
});
