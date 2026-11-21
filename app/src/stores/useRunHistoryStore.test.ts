import { describe, expect, it } from "vitest";
import {
  applyTombstones,
  mergeEntries,
  preferLocalCopy,
  useRunHistoryStore,
  type RunHistoryEntry,
  type Tombstones,
} from "./useRunHistoryStore";

/**
 * The run history lives in two windows at once, each seeing the other's runs
 * only through localStorage. These pin the two rules that had no test and
 * were both wrong: which copy of a run survives a merge, and that a removal
 * stays a removal.
 */

function entry(over: Partial<RunHistoryEntry> = {}): RunHistoryEntry {
  return {
    id: "run-1",
    folder: "ports",
    script: "Scan-Ports.ps1",
    label: "Scan",
    args: [],
    startedAt: "2026-11-21T10:00:00.000Z",
    finishedAt: "2026-11-21T10:00:05.000Z",
    exitCode: 0,
    output: [],
    droppedLines: 0,
    caution: false,
    detached: false,
    cancelled: false,
    ...over,
  };
}

const lines = (n: number) => Array.from({ length: n }, (_, i) => ({ stream: "stdout", line: `line ${i}` }));

/** How a run still in flight in the OTHER window arrives here: ended, outcome unknown. */
const seenThroughStorage = (n: number) =>
  entry({ finishedAt: "2026-11-21T10:00:00.000Z", exitCode: null, detached: true, output: lines(n) });

describe("preferLocalCopy", () => {
  it("keeps a copy this window is watching live", () => {
    const live = entry({ finishedAt: null, exitCode: null, output: lines(1) });
    expect(preferLocalCopy(live, entry({ output: lines(50) }))).toBe(true);
  });

  it("takes the real outcome over a stale 'unknown' copy with the same transcript", () => {
    // The bug: both copies carried the same number of lines, "richer or
    // equal" picked the local one, and the row said "unknown" forever.
    expect(preferLocalCopy(seenThroughStorage(12), entry({ exitCode: 3, output: lines(12) }))).toBe(false);
  });

  it("takes the real outcome even when the unknown copy has MORE lines", () => {
    expect(preferLocalCopy(seenThroughStorage(40), entry({ exitCode: 0, output: lines(12) }))).toBe(false);
  });

  it("does not trade a known outcome for an unknown one", () => {
    expect(preferLocalCopy(entry({ exitCode: 0, output: lines(2) }), seenThroughStorage(40))).toBe(true);
  });

  it("falls back to the longer transcript, and to the newer write on a tie", () => {
    expect(preferLocalCopy(entry({ output: lines(9) }), entry({ output: lines(3) }))).toBe(true);
    expect(preferLocalCopy(entry({ output: lines(3) }), entry({ output: lines(3) }))).toBe(false);
  });
});

describe("mergeEntries", () => {
  it("settles a run the other window finished", () => {
    const merged = mergeEntries([seenThroughStorage(5)], [entry({ exitCode: 0, output: lines(5) })], 50);
    expect(merged).toHaveLength(1);
    expect(merged[0].exitCode).toBe(0);
    expect(merged[0].detached).toBe(false);
  });

  it("keeps runs only one side knows about, newest first", () => {
    const mine = entry({ id: "mine", startedAt: "2026-11-21T11:00:00.000Z" });
    const theirs = entry({ id: "theirs", startedAt: "2026-11-21T12:00:00.000Z" });
    expect(mergeEntries([mine], [theirs], 50).map((e) => e.id)).toEqual(["theirs", "mine"]);
  });

  it("honours the limit", () => {
    const many = Array.from({ length: 10 }, (_, i) =>
      entry({ id: `r${i}`, startedAt: new Date(Date.UTC(2026, 10, 21, 10, i)).toISOString() }),
    );
    expect(mergeEntries(many, [], 4)).toHaveLength(4);
  });

  it("does not bring back a row the other window still has after it was dismissed here", () => {
    const removed: Tombstones = { clearedAt: null, ids: ["run-1"] };
    expect(mergeEntries([], [entry()], 50, removed)).toHaveLength(0);
  });

  it("does not bring back cleared history, but keeps a run started after the clear", () => {
    const removed: Tombstones = { clearedAt: "2026-11-21T10:30:00.000Z", ids: [] };
    const old = entry({ id: "old", startedAt: "2026-11-21T10:00:00.000Z" });
    const fresh = entry({ id: "fresh", startedAt: "2026-11-21T10:45:00.000Z" });
    expect(mergeEntries([], [old, fresh], 50, removed).map((e) => e.id)).toEqual(["fresh"]);
  });
});

describe("applyTombstones", () => {
  it("is a no-op without tombstones", () => {
    const list = [entry()];
    expect(applyTombstones(list, { clearedAt: null, ids: [] })).toBe(list);
  });

  it("ignores an unparseable clearedAt instead of dropping everything", () => {
    expect(applyTombstones([entry()], { clearedAt: "not a date", ids: [] })).toHaveLength(1);
  });
});

/**
 * A tool's output reaches the store in batches (see lib/lineBatcher.ts):
 * one update per batch, where each line used to be its own.
 */
describe("appendLines", () => {
  const spec = { folder: "ports", script: "Scan-Ports.ps1", label: "Scan", args: [] };
  const output = (id: string) => useRunHistoryStore.getState().entries.find((e) => e.id === id)?.output ?? [];

  it("adds a whole batch, in order, as ONE store update", () => {
    const store = useRunHistoryStore.getState();
    store.startRun("batch-1", spec);
    let updates = 0;
    const unsubscribe = useRunHistoryStore.subscribe(() => {
      updates += 1;
    });
    store.appendLines("batch-1", lines(250));
    unsubscribe();
    expect(updates).toBe(1);
    expect(output("batch-1")).toHaveLength(250);
    expect(output("batch-1")[0].line).toBe("line 0");
    expect(output("batch-1")[249].line).toBe("line 249");
  });

  it("keeps the newest lines and counts what fell off, across batches", () => {
    const store = useRunHistoryStore.getState();
    store.startRun("batch-2", spec);
    store.appendLines("batch-2", lines(250));
    store.appendLines("batch-2", lines(250));
    const entry = useRunHistoryStore.getState().entries.find((e) => e.id === "batch-2");
    expect(entry?.output).toHaveLength(300);
    expect(entry?.droppedLines).toBe(200);
    // The tail of the second batch is the end of the transcript.
    expect(entry?.output[299].line).toBe("line 249");
  });

  it("treats anything that is not stderr as stdout and shortens an absurd line", () => {
    const store = useRunHistoryStore.getState();
    store.startRun("batch-3", spec);
    store.appendLines("batch-3", [
      { stream: "stderr", line: "bad" },
      { stream: "something-else", line: "fine" },
      { stream: "stdout", line: "x".repeat(5000) },
    ]);
    const out = output("batch-3");
    expect(out.map((l) => l.stream)).toEqual(["stderr", "stdout", "stdout"]);
    expect(out[2].line.length).toBeLessThan(1100);
    expect(out[2].line.endsWith("[line truncated]")).toBe(true);
  });

  it("does nothing, and notifies nobody, for an empty batch or an unknown run", () => {
    const store = useRunHistoryStore.getState();
    let updates = 0;
    const unsubscribe = useRunHistoryStore.subscribe(() => {
      updates += 1;
    });
    store.appendLines("batch-1", []);
    store.appendLines("no-such-run", lines(3));
    unsubscribe();
    expect(updates).toBe(0);
  });

  it("appendLine is the same thing with one line", () => {
    const store = useRunHistoryStore.getState();
    store.startRun("batch-4", spec);
    store.appendLine("batch-4", "stderr", "only");
    expect(output("batch-4")).toEqual([{ stream: "stderr", line: "only" }]);
  });
});
