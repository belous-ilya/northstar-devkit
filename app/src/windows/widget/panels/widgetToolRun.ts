import { useSyncExternalStore } from "react";
import {
  TOOL_RESULT_GRACE_MS,
  droppedEventCount,
  droppedEventsNote,
  onDevKitEvent,
  parseRpcError,
  rpcCall,
  type ToolRunResult,
} from "../../../lib/ipc";
import { createLineBatcher } from "../../../lib/lineBatcher";
import { useRunHistoryStore, type RunSpec } from "../../../stores/useRunHistoryStore";
import { playSound } from "../../../lib/sounds";
import { nextConsoleLineId, type ToolConsoleLine } from "../../../components/ToolConsole";

/**
 * The widget's single tool-run channel, shared by Quick Actions and Node &
 * Ports.
 *
 * ONE store, not one per panel, because the sidecar has exactly one `tool`
 * lane (core/Invoke-DevKitRpc.ps1): a second tool.run sits in that lane's
 * queue until the first child process exits, so two panels each running
 * their own "is something in flight" flag would let the owner fire Kill All
 * Node on top of a Doctor run and then watch a button spin for a minute
 * with nothing happening. A shared in-flight guard makes the widget tell
 * the truth about a resource it does not actually own two of.
 *
 * The state lives in module scope rather than React state for the reason
 * the Quick Actions panel originally discovered: a run outlives the panel
 * that launched it. The widget slides into its tray, the panel order
 * changes, a parent re-keys - and an unmount used to drop the tool.output
 * subscription, reset the in-flight flag and re-enable every button, so a
 * second Kill All Node could be launched on top of the first. Keeping the
 * run and its event subscription outside React fixes both halves: the guard
 * survives unmount, and output keeps accumulating (and the history entry
 * still gets finalized with a real exit code) whether or not anyone is
 * rendering it.
 */

/** Which panel launched the run - only that panel renders its transcript. */
export type ToolRunSurface = "quick-actions" | "node-ports";

export interface WidgetRunSpec extends RunSpec {
  surface: ToolRunSurface;
  /**
   * Sent as tool.run's `confirmed`, which lets the sidecar append -Force to
   * scripts whose AST actually declares that parameter (see
   * Add-DevKitForceArgument in core/RpcMethods.ps1). Pass this ONLY after
   * the user has really been through the caution gate - it is the
   * difference between "the tool asks" and "the tool just does it".
   */
  confirmed?: boolean;
}

export interface WidgetToolRunSnapshot {
  /** runId of the in-flight run, or null when nothing is running. */
  runId: string | null;
  /** Label of the in-flight run - drives the per-button spinner. */
  label: string | null;
  /**
   * Surface of the MOST RECENT run, kept after it finishes so the panel
   * that launched it keeps its transcript and exit code while the other
   * panel stays quiet about a run it had nothing to do with.
   */
  surface: ToolRunSurface | null;
  lines: ToolConsoleLine[];
  exitCode: number | null;
  /** The tool.run RPC errored but the run is alive and still being watched. */
  degraded: boolean;
  /**
   * The run never started at all - the sidecar rejected tool.run before it
   * emitted a single event (missing script, spawn failure). Terminal, and
   * the reason a button for a tool that isn't installed yet reports itself
   * instead of spinning forever.
   */
  launchError: string | null;
}

/** Live console cap - the run history store keeps its own (deeper) copy. */
const MAX_LIVE_LINES = 400;

/**
 * How long streamed lines pile up before they are shown and recorded
 * together. Each line used to be its own snapshot (a render of the panel)
 * and its own history-store update; a tool printing a thousand lines a
 * second did both a thousand times. Same window as the Control Center's
 * run dialog.
 */
const STREAM_FLUSH_MS = 100;

const IDLE: WidgetToolRunSnapshot = {
  runId: null,
  label: null,
  surface: null,
  lines: [],
  exitCode: null,
  degraded: false,
  launchError: null,
};

// Module scope survives unmounts but NOT a webview reload: reloading during
// an in-flight run resets all of this while the sidecar's child process (and
// the single tool lane's occupancy) keeps going, and the fresh module does
// not know the runId - the lane can be busy with a phantom run no UI can see
// until the child exits and drains it. Rare and self-limiting; documented
// rather than solved.
let snapshot: WidgetToolRunSnapshot = IDLE;
let unlisten: (() => void) | null = null;
const subscribers = new Set<() => void>();

function setSnapshot(patch: Partial<WidgetToolRunSnapshot>): void {
  snapshot = { ...snapshot, ...patch };
  for (const notify of subscribers) notify();
}

function subscribe(notify: () => void): () => void {
  subscribers.add(notify);
  return () => {
    subscribers.delete(notify);
  };
}

function getSnapshot(): WidgetToolRunSnapshot {
  return snapshot;
}

/** Subscribes a component to the shared run. Safe to call from any panel. */
export function useWidgetToolRun(): WidgetToolRunSnapshot {
  return useSyncExternalStore(subscribe, getSnapshot);
}

function appendLive(stream: string, line: string): void {
  const lines = [...snapshot.lines, { id: nextConsoleLineId(), stream, line }];
  setSnapshot({ lines: lines.length > MAX_LIVE_LINES ? lines.slice(-MAX_LIVE_LINES) : lines });
}

/**
 * The in-flight run's streamed output on its way to the screen and to the
 * run's history entry. Anything that must come AFTER the output received
 * so far (the outcome, a notice) calls `streamed.flush()` first.
 */
const streamed = createLineBatcher<{ runId: string; stream: string; line: string }>((batch) => {
  // Lines of a run that has since been let go of still belong in its
  // history; only the current run's are shown.
  const byRun = new Map<string, { stream: string; line: string }[]>();
  for (const l of batch) {
    const group = byRun.get(l.runId);
    if (group) group.push(l);
    else byRun.set(l.runId, [l]);
  }
  const history = useRunHistoryStore.getState();
  for (const [runId, group] of byRun) history.appendLines(runId, group);
  const live = batch.filter((l) => l.runId === snapshot.runId);
  if (live.length === 0) return;
  const lines = [...snapshot.lines, ...live.map(({ stream, line }) => ({ id: nextConsoleLineId(), stream, line }))];
  setSnapshot({ lines: lines.length > MAX_LIVE_LINES ? lines.slice(-MAX_LIVE_LINES) : lines });
}, STREAM_FLUSH_MS);

function detachListener(): void {
  unlisten?.();
  unlisten = null;
}

/**
 * How a refused or failed launch reads on screen. tool.run's rejection
 * carries the sidecar's HostError display string ("sidecar returned an
 * error: toolLaneBusy (Another DevKit tool is already running…)");
 * parseRpcError recovers just the human message when the text matches that
 * wire format, and the raw text stands when it doesn't (local failures,
 * like the output subscription below, never carry a kind).
 */
function describeLaunchFailure(err: unknown): string {
  const parsed = parseRpcError(err);
  return parsed.kind !== null ? parsed.message : String(err);
}

/** Ends a run that was never actually launched, with the reason on screen. */
function failLaunch(runId: string, message: string): void {
  detachListener();
  streamed.flush();
  appendLive("stderr", message);
  setSnapshot({ runId: null, label: null, exitCode: -1, degraded: false, launchError: message });
  const history = useRunHistoryStore.getState();
  history.appendLine(runId, "stderr", message);
  history.finishRun(runId, -1);
  playSound("error");
}

/**
 * Launches a tool run. Refuses to start while another is in flight - that
 * guard is module-level state, so it holds across unmounts AND across the
 * two panels that share this channel.
 *
 * The tool.run rejection is split into two very different outcomes, because
 * conflating them is what turns a typo'd script name into a permanently
 * dead button:
 *
 *  - Nothing has been heard from the sidecar for this runId yet, so it
 *    never got as far as spawning a child (the classic case: "Tool script
 *    not found"). No tool.finished is ever coming; finalize now and say so.
 *  - At least one event has arrived, so a real process exists and the
 *    rejection is about the REQUEST (a timeout, most likely), not the run.
 *    The run is real and still going, so keep listening and only mark
 *    the run degraded - same rule the Control Center's ToolRunDialog uses.
 *
 * `sawEvent` is a better discriminator than matching the error text: any
 * pre-spawn failure produces silence, and every post-spawn one is preceded
 * by tool.started, which the sidecar emits immediately after Process.Start.
 */
export async function startWidgetToolRun(spec: WidgetRunSpec): Promise<void> {
  if (snapshot.runId) return;

  const runId = crypto.randomUUID();
  setSnapshot({
    runId,
    label: spec.label,
    surface: spec.surface,
    lines: [],
    exitCode: null,
    degraded: false,
    launchError: null,
  });
  const history = () => useRunHistoryStore.getState();
  history().startRun(runId, spec);

  let sawEvent = false;

  // Ends the run. Reached from the tool.finished event and, when that event
  // never arrives, from the tool.run answer (see TOOL_RESULT_GRACE_MS);
  // whichever comes second finds the run no longer current and does nothing.
  const settle = (code: number, cancelled: boolean) => {
    if (snapshot.runId !== runId) return;
    streamed.flush();
    detachListener();
    setSnapshot({ runId: null, label: null, exitCode: code, degraded: false });
    history().finishRun(runId, code, cancelled);
    playSound(code === 0 ? "success" : "error");
  };

  try {
    unlisten = await onDevKitEvent((evt) => {
      const dropped = droppedEventCount(evt);
      if (dropped !== null) {
        if (snapshot.runId === runId) streamed.push({ runId, stream: "stderr", line: droppedEventsNote(dropped) });
        return;
      }
      if (evt.runId !== runId) return;
      sawEvent = true;
      if (snapshot.runId !== runId) return;
      if (evt.event === "tool.output" && evt.stream && evt.line !== undefined) {
        streamed.push({ runId, stream: evt.stream, line: evt.line });
      } else if (evt.event === "tool.finished") {
        settle(Number(evt.exitCode ?? -1), evt.cancelled === true);
      }
    });
  } catch (err) {
    // Failing to subscribe at all is terminal in the other direction:
    // nothing in this window would ever finalize the run.
    failLaunch(runId, `Could not subscribe to run output: ${describeLaunchFailure(err)}`);
    return;
  }

  try {
    const result = await rpcCall<ToolRunResult>("tool.run", {
      folder: spec.folder,
      script: spec.script,
      args: spec.args,
      runId,
      ...(spec.confirmed ? { confirmed: true } : {}),
    });
    // The tool has exited. Its outcome normally arrives as tool.finished -
    // but events are dropped when a tool floods the app with output
    // (host.lagged), and a dropped tool.finished left the shared guard shut
    // and every action button in both panels disabled. This answer cannot
    // be dropped, so it settles the run if the event has not by then.
    setTimeout(() => {
      const code = Number(result?.exitCode ?? -1);
      const cancelled = result?.cancelled === true;
      if (snapshot.runId === runId) {
        settle(code, cancelled);
        return;
      }
      // Let go of earlier ("Stop watching"): nobody was listening when it
      // ended, but its outcome is known now, so its history row gets it
      // instead of staying "outcome unknown".
      const entry = history().entries.find((e) => e.id === runId);
      if (entry && entry.exitCode === null) history().finishRun(runId, code, cancelled);
    }, TOOL_RESULT_GRACE_MS);
  } catch (err) {
    if (snapshot.runId !== runId) return;
    if (!sawEvent) {
      failLaunch(runId, `Couldn't start ${spec.script}: ${describeLaunchFailure(err)}`);
      return;
    }
    const message = `RPC error: ${String(err)} - the tool may still be running; still watching for it to finish.`;
    streamed.flush();
    appendLive("stderr", message);
    history().appendLine(runId, "stderr", message);
    setSnapshot({ degraded: true });
  }
}

/**
 * Detaches from the in-flight run. NOT cancellation - nothing this button
 * does stops the tool (the run's row in Run history has the Stop that
 * does). It exists only so a run whose tool.finished will never arrive
 * can't hold the shared guard - and therefore every action button in both
 * panels - shut for the rest of the session.
 */
export function stopWatchingWidgetRun(): void {
  const runId = snapshot.runId;
  detachListener();
  if (runId) {
    const message = "Stopped watching - the tool may still be running. Its row in Run history has a Stop button.";
    streamed.flush();
    appendLive("stderr", message);
    useRunHistoryStore.getState().appendLine(runId, "stderr", message);
    useRunHistoryStore.getState().detachRun(runId);
  }
  setSnapshot({ runId: null, label: null, degraded: false });
}
