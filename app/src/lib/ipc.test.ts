import { beforeEach, describe, expect, it, vi } from "vitest";

// The one Tauri call these tests reach: `listen`. The stand-in keeps the
// handler so a test can deliver events to it the way the app's forwarder does.
const delivered: { handler: ((e: { payload: unknown }) => void) | null } = { handler: null };
vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async (_name: string, handler: (e: { payload: unknown }) => void) => {
    delivered.handler = handler;
    return () => {
      delivered.handler = null;
    };
  }),
}));

import { droppedEventCount, droppedEventsNote, onToolRun, parseRpcError } from "./ipc";

/**
 * parseRpcError recovers { kind, message } from the flat string the invoke
 * boundary rejects with. The format is HostError::Remote's Display,
 * constructed as Remote(kind, message):
 *   "sidecar returned an error: {KIND} ({message})"  (kind FIRST)
 * See crates/devkit-host/src/host.rs. These cases pin that wire format -
 * a kind/message inversion here silently breaks every kind-based branch
 * (e.g. the tool-lane-busy UX) downstream.
 */
describe("parseRpcError", () => {
  it("parses a real sidecar refusal frame to kind + exact message", () => {
    const rejection = parseRpcError(
      "sidecar returned an error: toolLaneBusy (Another DevKit tool is already running. Wait for it to finish or stop it first.)",
    );
    expect(rejection.kind).toBe("toolLaneBusy");
    expect(rejection.message).toBe("Another DevKit tool is already running. Wait for it to finish or stop it first.");
    expect(rejection.raw).toBe(
      "sidecar returned an error: toolLaneBusy (Another DevKit tool is already running. Wait for it to finish or stop it first.)",
    );
  });

  it("returns a null kind for transport-level failures", () => {
    const rejection = parseRpcError("sidecar process is not running");
    expect(rejection.kind).toBeNull();
    expect(rejection.message).toBe("sidecar process is not running");
    expect(rejection.raw).toBe("sidecar process is not running");
  });

  it("round-trips a message that itself contains parentheses", () => {
    const rejection = parseRpcError("sidecar returned an error: ToolFailed (boom (mid-dle) done.)");
    expect(rejection.kind).toBe("ToolFailed");
    expect(rejection.message).toBe("boom (mid-dle) done.");
  });

  it("unwraps Error objects to their message before parsing", () => {
    const rejection = parseRpcError(new Error("sidecar returned an error: BadParams (missing folder)"));
    expect(rejection.kind).toBe("BadParams");
    expect(rejection.message).toBe("missing folder");
  });

  it("does not misfire on kind-last text", () => {
    // The pre-fix regex expected message-first/kind-last and would have
    // parsed this as kind "toolLaneBusy" + message "Other text"; kind-first
    // means the leading token must be the kind.
    const rejection = parseRpcError("sidecar returned an error: toolLaneBusy (real message) (other)");
    expect(rejection.kind).toBe("toolLaneBusy");
    expect(rejection.message).toBe("real message) (other");
  });
});

/**
 * `host.lagged` is what app/src-tauri/src/lib.rs emits when a tool writes
 * output faster than it can be forwarded and events had to be dropped. It
 * carries no runId: any of the dropped events may have belonged to any run.
 */
describe("droppedEventCount", () => {
  it("reads the count from a host.lagged notice", () => {
    expect(droppedEventCount({ event: "host.lagged", data: { dropped: 37 } })).toBe(37);
  });

  it("is null for every other event, so callers can tell the notice apart", () => {
    expect(droppedEventCount({ event: "tool.output", runId: "a", stream: "stdout", line: "x" })).toBeNull();
    expect(droppedEventCount({ event: "tool.finished", runId: "a", exitCode: 0 })).toBeNull();
  });

  it("still recognises a notice whose count is missing or not a number", () => {
    expect(droppedEventCount({ event: "host.lagged" })).toBe(0);
    expect(droppedEventCount({ event: "host.lagged", data: null })).toBe(0);
    expect(droppedEventCount({ event: "host.lagged", data: { dropped: "many" } })).toBe(0);
    expect(droppedEventCount({ event: "host.lagged", data: { dropped: -4 } })).toBe(0);
  });
});

describe("droppedEventsNote", () => {
  it("says how many and that lines are missing", () => {
    const note = droppedEventsNote(1200);
    expect(note).toContain("1,200 output events were dropped");
    expect(note).toContain("Some lines are missing");
  });

  it("is singular for one", () => {
    expect(droppedEventsNote(1)).toContain("1 output event was dropped");
  });

  it("does not invent a number it was not given", () => {
    expect(droppedEventsNote(0)).toContain("-- output events were dropped");
  });
});

describe("onToolRun", () => {
  beforeEach(() => {
    delivered.handler = null;
  });

  const deliver = (payload: unknown) => delivered.handler?.({ payload });

  it("passes a run its own events and nobody else's", async () => {
    const seen: string[] = [];
    await onToolRun("mine", {
      onStarted: (pid) => seen.push(`started ${pid}`),
      onOutput: (stream, line) => seen.push(`${stream}: ${line}`),
      onFinished: (code, cancelled) => seen.push(`finished ${code} ${cancelled}`),
    });
    deliver({ event: "tool.started", runId: "mine", pid: 4821 });
    deliver({ event: "tool.output", runId: "other", stream: "stdout", line: "not mine" });
    deliver({ event: "tool.output", runId: "mine", stream: "stderr", line: "oops" });
    deliver({ event: "tool.finished", runId: "mine", exitCode: 3, cancelled: true });
    expect(seen).toEqual(["started 4821", "stderr: oops", "finished 3 true"]);
  });

  it("tells every watching run about dropped events, which name no run", async () => {
    const dropped: number[] = [];
    const lines: string[] = [];
    await onToolRun("mine", { onLagged: (n) => dropped.push(n), onOutput: (_s, line) => lines.push(line) });
    deliver({ event: "host.lagged", data: { dropped: 512 } });
    expect(dropped).toEqual([512]);
    expect(lines).toEqual([]);
  });

  it("ignores a dropped-events notice when the caller did not ask for them", async () => {
    await onToolRun("mine", {});
    expect(() => deliver({ event: "host.lagged", data: { dropped: 5 } })).not.toThrow();
  });
});
