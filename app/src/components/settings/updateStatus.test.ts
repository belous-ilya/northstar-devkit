import { describe, expect, it } from "vitest";
import { updateRowView, type UpdateRowInput } from "./updateStatus";
import type { UpdateCheckStatus } from "../../stores/useUpdaterStore";

const base: UpdateRowInput = { status: "idle", version: null, progress: null, error: null, failedStep: null };

describe("updateRowView", () => {
  it("offers Install & Restart as soon as an update is known - in whichever window Settings is open", () => {
    // The dead end this exists for: Settings in the Control Center said
    // "v4.8.0 available" and offered nothing to click, because only the
    // widget renders the install dialog.
    const view = updateRowView({ ...base, status: "available", version: "4.8.0" });
    expect(view.label).toBe("v4.8.0 available");
    expect(view.tone).toBe("available");
    expect(view.installLabel).toBe("Install & Restart");
    expect(view.busy).toBe(false);
  });

  it("never shows 'available' without a way to install", () => {
    const statuses: UpdateCheckStatus[] = ["idle", "checking", "available", "up-to-date", "error", "downloading", "installing"];
    for (const status of statuses) {
      for (const version of ["4.8.0", null]) {
        const view = updateRowView({ ...base, status, version });
        if (view.tone === "available") expect(view.installLabel).not.toBeNull();
      }
    }
  });

  it("says nothing and offers nothing before the first check", () => {
    expect(updateRowView(base)).toEqual({ label: null, tone: "neutral", installLabel: null, busy: false });
  });

  it("holds both buttons still while checking, downloading and installing", () => {
    for (const status of ["checking", "downloading", "installing"] as const) {
      const view = updateRowView({ ...base, status, version: "4.8.0" });
      expect(view.busy).toBe(true);
      expect(view.installLabel).toBeNull();
    }
  });

  it("shows download progress when the size is known, and no number when it is not", () => {
    const half = updateRowView({ ...base, status: "downloading", version: "4.8.0", progress: { downloaded: 1_500_000, total: 3_000_000 } });
    expect(half.label).toBe("Downloading… 50%");
    const unknown = updateRowView({ ...base, status: "downloading", version: "4.8.0", progress: { downloaded: 1_500_000, total: null } });
    expect(unknown.label).toBe("Downloading…");
    const over = updateRowView({ ...base, status: "downloading", version: "4.8.0", progress: { downloaded: 9, total: 3 } });
    expect(over.label).toBe("Downloading… 100%");
  });

  it("tells a failed install from a failed check, and offers a retry only for the install", () => {
    const install = updateRowView({ ...base, status: "error", version: "4.8.0", error: "signature mismatch", failedStep: "install" });
    expect(install.label).toBe("Install failed: signature mismatch");
    expect(install.installLabel).toBe("Retry & Restart");
    expect(install.tone).toBe("error");

    const check = updateRowView({ ...base, status: "error", version: null, error: "offline", failedStep: "check" });
    expect(check.label).toBe("Check failed: offline");
    expect(check.installLabel).toBeNull();
  });

  it("does not call a failed RE-check a failed install, and keeps the earlier update installable", () => {
    // An update was found, then a later check failed (offline). The update
    // object is still held: that used to read as "the install failed".
    const view = updateRowView({ ...base, status: "error", version: "4.8.0", error: "offline", failedStep: "check" });
    expect(view.label).toBe("Check failed: offline");
    expect(view.installLabel).toBe("Install & Restart");
  });

  it("reports up to date plainly", () => {
    expect(updateRowView({ ...base, status: "up-to-date" })).toEqual({ label: "Up to date", tone: "neutral", installLabel: null, busy: false });
  });
});
