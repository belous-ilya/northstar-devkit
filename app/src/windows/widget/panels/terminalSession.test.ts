import { describe, expect, it } from "vitest";
import { folderLabel, isSessionElsewhere, sessionCwdFor } from "./terminalSession";

describe("sessionCwdFor", () => {
  it("is the project's folder", () => {
    expect(sessionCwdFor({ path: "D:\\Work\\app", Missing: false })).toBe("D:\\Work\\app");
  });

  it("is the default folder when no project is selected", () => {
    expect(sessionCwdFor(null)).toBeUndefined();
  });

  it("is the default folder when the project's folder is gone (ConPTY cannot start there)", () => {
    expect(sessionCwdFor({ path: "D:\\Work\\deleted", Missing: true })).toBeUndefined();
  });
});

describe("isSessionElsewhere", () => {
  it("is false while the session is in the active project's folder", () => {
    expect(isSessionElsewhere("D:\\Work\\app", "D:\\Work\\app")).toBe(false);
  });

  it("ignores case, slash direction and a trailing slash - the same Windows folder", () => {
    expect(isSessionElsewhere("D:\\Work\\App\\", "d:/work/app")).toBe(false);
  });

  it("is true after the active project changed under a running session", () => {
    expect(isSessionElsewhere("D:\\Work\\app", "D:\\Work\\other")).toBe(true);
  });

  it("is true when a session started with no project and one is selected later, and the reverse", () => {
    expect(isSessionElsewhere(undefined, "D:\\Work\\app")).toBe(true);
    expect(isSessionElsewhere("D:\\Work\\app", undefined)).toBe(true);
  });

  it("is false with no project on either side", () => {
    expect(isSessionElsewhere(undefined, undefined)).toBe(false);
  });
});

describe("folderLabel", () => {
  it("is the last segment of the path", () => {
    expect(folderLabel("D:\\Dev-Ops\\Red_Hen\\Red_Hen")).toBe("Red_Hen");
    expect(folderLabel("D:/Work/app/")).toBe("app");
  });

  it("names the default folder when there is no path", () => {
    expect(folderLabel(undefined)).toBe("the default folder");
  });

  it("keeps a drive root readable", () => {
    expect(folderLabel("D:\\")).toBe("D:");
  });
});
