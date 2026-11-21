import { useSyncExternalStore } from "react";

/**
 * A second reason to stop polling, beside useVisibility: the window is on
 * screen, but nothing in it can be seen.
 *
 * The case this exists for is the docked widget collapsed to its sliver.
 * The OS window is still visible (that 18px strip IS the window), so
 * useVisibility says "visible" and every panel kept polling the sidecar at
 * full rate - metrics.system's two CIM queries every 2s, env.drift, the
 * error feed - to redraw gauges parked off the edge of the monitor.
 *
 * Deliberately NOT folded into useVisibility: that hook also drives
 * main.tsx's WindowEffectsGate, which pauses every CSS animation and
 * transition - and the collapsed sliver's breathing light and the glide back
 * out are exactly the animations that must keep running while collapsed.
 *
 * Module state, like useVisibility: each Tauri window is its own JS context,
 * so the widget suspending its polls never touches the Control Center's.
 */

let suspended = false;
const listeners = new Set<() => void>();

/** Called by whoever knows the window's content is out of sight (WidgetApp, on collapse). */
export function setPollingSuspended(next: boolean): void {
  if (suspended === next) return;
  suspended = next;
  for (const notify of listeners) notify();
}

/** The store's subscribe half - exported for the unit test; components use the hook. */
export function subscribePollGate(notify: () => void): () => void {
  listeners.add(notify);
  return () => {
    listeners.delete(notify);
  };
}

/** The store's snapshot half - exported for the unit test; components use the hook. */
export function isPollingSuspended(): boolean {
  return suspended;
}

/** True while polled queries in this window should hold still. */
export function usePollingSuspended(): boolean {
  return useSyncExternalStore(subscribePollGate, isPollingSuspended);
}
