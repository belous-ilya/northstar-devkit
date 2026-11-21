import { describe, expect, it } from "vitest";
import {
  PALETTE_HANDOFF_KEY,
  PALETTE_HANDOFF_MAX_AGE_MS,
  clearStashedToolRequest,
  stashToolRequest,
  takeStashedToolRequest,
  type PaletteToolRequest,
} from "./paletteStore";

/** A Map behind the three Storage methods the handoff uses. */
function fakeStorage(initial: Record<string, string> = {}) {
  const items = new Map(Object.entries(initial));
  return {
    items,
    getItem: (key: string) => items.get(key) ?? null,
    setItem: (key: string, value: string) => void items.set(key, value),
    removeItem: (key: string) => void items.delete(key),
  };
}

const request: PaletteToolRequest = {
  id: "req-1",
  folder: "wifi",
  script: "WiFi-Optimize.ps1",
  key: "check",
  label: "Check",
};

describe("palette tool handoff", () => {
  // The Control Center window is created on first use, so the pick that
  // opens it is emitted before the window can hear it.

  it("hands a request to a window that mounts after it was made", () => {
    const storage = fakeStorage();
    stashToolRequest(request, storage, 1_000);
    expect(takeStashedToolRequest(storage, 1_400)).toEqual(request);
  });

  it("hands it over once", () => {
    const storage = fakeStorage();
    stashToolRequest(request, storage, 1_000);
    takeStashedToolRequest(storage, 1_400);
    expect(takeStashedToolRequest(storage, 1_500)).toBeNull();
    expect(storage.items.has(PALETTE_HANDOFF_KEY)).toBe(false);
  });

  it("drops a request the user stopped waiting for", () => {
    const storage = fakeStorage();
    stashToolRequest(request, storage, 1_000);
    expect(takeStashedToolRequest(storage, 1_000 + PALETTE_HANDOFF_MAX_AGE_MS + 1)).toBeNull();
    // ...and does not leave it lying around for the next mount.
    expect(storage.items.has(PALETTE_HANDOFF_KEY)).toBe(false);
  });

  it("still hands over a request exactly at the age limit", () => {
    const storage = fakeStorage();
    stashToolRequest(request, storage, 1_000);
    expect(takeStashedToolRequest(storage, 1_000 + PALETTE_HANDOFF_MAX_AGE_MS)).toEqual(request);
  });

  it("drops a request stamped in the future (a clock that was set back)", () => {
    const storage = fakeStorage();
    stashToolRequest(request, storage, 10_000);
    expect(takeStashedToolRequest(storage, 5_000)).toBeNull();
  });

  it("forgets a request that was delivered live", () => {
    const storage = fakeStorage();
    stashToolRequest(request, storage, 1_000);
    clearStashedToolRequest(storage);
    expect(takeStashedToolRequest(storage, 1_100)).toBeNull();
  });

  it("answers null when nothing is waiting", () => {
    expect(takeStashedToolRequest(fakeStorage(), 1_000)).toBeNull();
  });

  it.each([
    ["not JSON", "{oops"],
    ["a bare value", "42"],
    ["null", "null"],
    ["no timestamp", JSON.stringify({ request })],
    ["no request", JSON.stringify({ at: 1_000 })],
    ["a request without an id", JSON.stringify({ at: 1_000, request: { ...request, id: "" } })],
    ["a request missing a field", JSON.stringify({ at: 1_000, request: { id: "x", folder: "wifi" } })],
  ])("drops and removes a stored value that is %s", (_name, stored) => {
    const storage = fakeStorage({ [PALETTE_HANDOFF_KEY]: stored });
    expect(takeStashedToolRequest(storage, 1_100)).toBeNull();
    expect(storage.items.has(PALETTE_HANDOFF_KEY)).toBe(false);
  });

  it("keeps only the fields a request has", () => {
    const storage = fakeStorage({
      [PALETTE_HANDOFF_KEY]: JSON.stringify({ at: 1_000, request: { ...request, extra: "ignored" } }),
    });
    expect(takeStashedToolRequest(storage, 1_100)).toEqual(request);
  });

  it("never throws when storage is unavailable or refuses", () => {
    const refusing = {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("full");
      },
      removeItem: () => {
        throw new Error("blocked");
      },
    };
    expect(() => stashToolRequest(request, refusing, 1_000)).not.toThrow();
    expect(() => clearStashedToolRequest(refusing)).not.toThrow();
    expect(takeStashedToolRequest(refusing, 1_000)).toBeNull();
    expect(() => stashToolRequest(request, null, 1_000)).not.toThrow();
    expect(takeStashedToolRequest(null, 1_000)).toBeNull();
  });
});
