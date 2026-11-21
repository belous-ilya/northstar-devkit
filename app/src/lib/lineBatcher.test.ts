import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createLineBatcher } from "./lineBatcher";

describe("createLineBatcher", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("delivers a burst of lines as one batch, in order", () => {
    const batches: string[][] = [];
    const batcher = createLineBatcher<string>((lines) => batches.push(lines), 100);
    for (let i = 0; i < 500; i++) batcher.push(`line ${i}`);
    expect(batches).toEqual([]);
    vi.advanceTimersByTime(100);
    expect(batches).toHaveLength(1);
    expect(batches[0]).toHaveLength(500);
    expect(batches[0][0]).toBe("line 0");
    expect(batches[0][499]).toBe("line 499");
  });

  it("never holds a line longer than the delay", () => {
    const batches: string[][] = [];
    const batcher = createLineBatcher<string>((lines) => batches.push(lines), 100);
    batcher.push("a");
    vi.advanceTimersByTime(60);
    batcher.push("b"); // must not restart the clock for "a"
    vi.advanceTimersByTime(40);
    expect(batches).toEqual([["a", "b"]]);
  });

  it("starts a new window after each delivery", () => {
    const batches: string[][] = [];
    const batcher = createLineBatcher<string>((lines) => batches.push(lines), 100);
    batcher.push("a");
    vi.advanceTimersByTime(100);
    batcher.push("b");
    vi.advanceTimersByTime(100);
    expect(batches).toEqual([["a"], ["b"]]);
  });

  it("flush delivers at once and leaves nothing for the timer", () => {
    const batches: string[][] = [];
    const batcher = createLineBatcher<string>((lines) => batches.push(lines), 100);
    batcher.push("a");
    batcher.flush();
    expect(batches).toEqual([["a"]]);
    vi.advanceTimersByTime(500);
    expect(batches).toEqual([["a"]]);
  });

  it("flush with nothing pending delivers nothing", () => {
    const deliver = vi.fn();
    const batcher = createLineBatcher<string>(deliver, 100);
    batcher.flush();
    vi.advanceTimersByTime(500);
    expect(deliver).not.toHaveBeenCalled();
  });

  it("take hands back what is pending without delivering it", () => {
    const deliver = vi.fn();
    const batcher = createLineBatcher<string>(deliver, 100);
    batcher.push("a");
    batcher.push("b");
    expect(batcher.take()).toEqual(["a", "b"]);
    vi.advanceTimersByTime(500);
    expect(deliver).not.toHaveBeenCalled();
    expect(batcher.take()).toEqual([]);
  });

  it("a line pushed while a batch is being delivered goes into the next one", () => {
    const batches: string[][] = [];
    const batcher = createLineBatcher<string>((lines) => {
      batches.push(lines);
      if (lines[0] === "a") batcher.push("from inside");
    }, 100);
    batcher.push("a");
    vi.advanceTimersByTime(100);
    vi.advanceTimersByTime(100);
    expect(batches).toEqual([["a"], ["from inside"]]);
  });
});
