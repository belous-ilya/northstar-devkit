import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DevKitRpcEvent } from "../../../lib/ipc";

/**
 * The widget's run channel against a stand-in sidecar: events are delivered
 * by hand and the `tool.run` call answers when the test says so. That makes
 * the two failure shapes reproducible that a real run only shows under load:
 * output arriving faster than it can be shown, and the `tool.finished` event
 * never arriving at all.
 */

const sidecar = vi.hoisted(() => ({
  handler: null as ((evt: unknown) => void) | null,
  answer: null as ((value: unknown) => void) | null,
  refuse: null as ((reason: unknown) => void) | null,
}));

vi.mock("../../../lib/ipc", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../../lib/ipc")>();
  return {
    ...actual,
    onDevKitEvent: vi.fn(async (handler: (evt: unknown) => void) => {
      sidecar.handler = handler;
      return () => {
        sidecar.handler = null;
      };
    }),
    rpcCall: vi.fn(
      () =>
        new Promise((resolve, reject) => {
          sidecar.answer = resolve;
          sidecar.refuse = reject;
        }),
    ),
  };
});
vi.mock("../../../lib/sounds", () => ({ playSound: vi.fn() }));

import { TOOL_RESULT_GRACE_MS } from "../../../lib/ipc";
import { useRunHistoryStore } from "../../../stores/useRunHistoryStore";
import { startWidgetToolRun, stopWatchingWidgetRun, useWidgetToolRun } from "./widgetToolRun";

// The snapshot is module state behind a React hook; read it the way the
// hook does, without React.
vi.mock("react", async (importOriginal) => {
  const actual = await importOriginal<typeof import("react")>();
  return { ...actual, useSyncExternalStore: (_subscribe: unknown, getSnapshot: () => unknown) => getSnapshot() };
});
const snapshot = () => useWidgetToolRun();

const spec = { folder: "ports", script: "Scan-Ports.ps1", label: "Scan", args: [], surface: "quick-actions" as const };
const send = (evt: DevKitRpcEvent) => sidecar.handler?.(evt);
const historyEntry = (id: string) => useRunHistoryStore.getState().entries.find((e) => e.id === id);

/** Starts a run and returns its id, with the subscription and the tool.run call both in place. */
async function begin(): Promise<string> {
  // Not awaited: it resolves only when tool.run answers, which the test decides.
  void startWidgetToolRun(spec);
  await vi.advanceTimersByTimeAsync(0);
  const runId = snapshot().runId;
  if (!runId) throw new Error("the run did not start");
  return runId;
}

describe("the widget's tool run channel", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(async () => {
    // Leave no run in flight for the next test: the guard is module state.
    const runId = snapshot().runId;
    if (runId) {
      send({ event: "tool.finished", runId, exitCode: 0 });
    }
    sidecar.answer?.({ runId: "x", exitCode: 0, cancelled: false });
    await vi.advanceTimersByTimeAsync(TOOL_RESULT_GRACE_MS + 200);
    vi.useRealTimers();
  });

  it("shows and records a burst of output together, not line by line", async () => {
    const runId = await begin();
    let storeUpdates = 0;
    const unsubscribe = useRunHistoryStore.subscribe(() => {
      storeUpdates += 1;
    });
    for (let i = 0; i < 400; i++) send({ event: "tool.output", runId, stream: "stdout", line: `line ${i}` });

    // Nothing yet: the lines are being collected.
    expect(snapshot().lines).toHaveLength(0);
    expect(storeUpdates).toBe(0);

    await vi.advanceTimersByTimeAsync(100);
    unsubscribe();
    expect(snapshot().lines).toHaveLength(400);
    expect(snapshot().lines[399].line).toBe("line 399");
    expect(storeUpdates).toBe(1);
    expect(historyEntry(runId)?.output).toHaveLength(300); // the store's own cap
    expect(historyEntry(runId)?.droppedLines).toBe(100);
  });

  it("gives every live line an id of its own, so a full console only touches what changed", async () => {
    const runId = await begin();
    for (let i = 0; i < 3; i++) send({ event: "tool.output", runId, stream: "stdout", line: `line ${i}` });
    await vi.advanceTimersByTimeAsync(100);
    const ids = snapshot().lines.map((l) => l.id);
    expect(ids.every((id) => typeof id === "number")).toBe(true);
    expect(new Set(ids).size).toBe(3);
  });

  it("ends the run on tool.finished, with the last lines already in place", async () => {
    const runId = await begin();
    send({ event: "tool.output", runId, stream: "stdout", line: "last words" });
    send({ event: "tool.finished", runId, exitCode: 3 });

    // No timer has run: finishing flushes what was pending.
    expect(snapshot().runId).toBeNull();
    expect(snapshot().exitCode).toBe(3);
    expect(snapshot().lines.map((l) => l.line)).toEqual(["last words"]);
    expect(historyEntry(runId)?.exitCode).toBe(3);
    expect(historyEntry(runId)?.output.map((l) => l.line)).toEqual(["last words"]);
  });

  it("ends the run from the tool.run answer when tool.finished never arrives", async () => {
    const runId = await begin();
    send({ event: "tool.started", runId, pid: 4821 });
    send({ event: "tool.output", runId, stream: "stdout", line: "working" });

    // The tool exits. Its tool.finished event is among those dropped.
    sidecar.answer?.({ runId, exitCode: 0, cancelled: false });
    await vi.advanceTimersByTimeAsync(TOOL_RESULT_GRACE_MS - 1);
    expect(snapshot().runId).toBe(runId); // still giving the event its chance

    await vi.advanceTimersByTimeAsync(1);
    expect(snapshot().runId).toBeNull(); // the guard is released: buttons work again
    expect(snapshot().exitCode).toBe(0);
    expect(historyEntry(runId)?.finishedAt).not.toBeNull();
    expect(historyEntry(runId)?.exitCode).toBe(0);
  });

  it("does not end a run twice when the event and the answer both arrive", async () => {
    const runId = await begin();
    send({ event: "tool.finished", runId, exitCode: 7 });
    const finishedAt = historyEntry(runId)?.finishedAt;
    sidecar.answer?.({ runId, exitCode: 7, cancelled: false });
    await vi.advanceTimersByTimeAsync(TOOL_RESULT_GRACE_MS + 10);
    expect(snapshot().exitCode).toBe(7);
    expect(historyEntry(runId)?.finishedAt).toBe(finishedAt);
  });

  it("says so in the console when output was dropped", async () => {
    const runId = await begin();
    send({ event: "host.lagged", data: { dropped: 900 } });
    await vi.advanceTimersByTimeAsync(100);
    const shown = snapshot().lines.map((l) => l.line);
    expect(shown).toHaveLength(1);
    expect(shown[0]).toContain("900 output events were dropped");
    expect(snapshot().lines[0].stream).toBe("stderr");
    expect(historyEntry(runId)?.output[0].line).toContain("900 output events were dropped");
  });

  it("gives a run that was let go of its real outcome once the tool exits", async () => {
    const runId = await begin();
    send({ event: "tool.started", runId, pid: 4821 });
    stopWatchingWidgetRun();
    expect(snapshot().runId).toBeNull();
    // Recorded as ended with its outcome unknown, and still stoppable.
    expect(historyEntry(runId)?.exitCode).toBeNull();
    expect(historyEntry(runId)?.detached).toBe(true);

    sidecar.answer?.({ runId, exitCode: 2, cancelled: false });
    await vi.advanceTimersByTimeAsync(TOOL_RESULT_GRACE_MS);
    expect(historyEntry(runId)?.exitCode).toBe(2);
    expect(historyEntry(runId)?.detached).toBe(false);
  });

  it("reports a tool that never started instead of waiting for it", async () => {
    const runId = await begin();
    sidecar.refuse?.("sidecar returned an error: ToolNotFound (Tool script not found: Scan-Ports.ps1)");
    await vi.advanceTimersByTimeAsync(0);
    expect(snapshot().runId).toBeNull();
    expect(snapshot().launchError).toContain("Tool script not found");
    expect(historyEntry(runId)?.exitCode).toBe(-1);
  });
});
