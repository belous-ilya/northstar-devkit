import { afterEach, describe, expect, it, vi } from "vitest";
import { isPollingSuspended, setPollingSuspended, subscribePollGate } from "./usePollGate";

/**
 * The gate is a tiny external store, but it is what stands between a
 * collapsed widget and a sidecar answering queries nobody can see - and
 * every usePolledRpc instance re-renders on each notification, so "notify on
 * a change, and only on a change" is worth pinning.
 */
describe("usePollGate", () => {
  afterEach(() => setPollingSuspended(false));

  it("starts not suspended", () => {
    expect(isPollingSuspended()).toBe(false);
  });

  it("notifies subscribers when the value changes", () => {
    const notify = vi.fn();
    const unsubscribe = subscribePollGate(notify);
    setPollingSuspended(true);
    expect(isPollingSuspended()).toBe(true);
    expect(notify).toHaveBeenCalledTimes(1);
    setPollingSuspended(false);
    expect(isPollingSuspended()).toBe(false);
    expect(notify).toHaveBeenCalledTimes(2);
    unsubscribe();
  });

  it("stays quiet when set to the value it already holds", () => {
    const notify = vi.fn();
    const unsubscribe = subscribePollGate(notify);
    setPollingSuspended(false);
    setPollingSuspended(true);
    setPollingSuspended(true);
    expect(notify).toHaveBeenCalledTimes(1);
    unsubscribe();
  });

  it("stops notifying after unsubscribe", () => {
    const notify = vi.fn();
    const unsubscribe = subscribePollGate(notify);
    unsubscribe();
    setPollingSuspended(true);
    expect(notify).not.toHaveBeenCalled();
  });
});
