/**
 * Typed wrapper around the single generic `rpc_call` Tauri command, which
 * forwards to the long-lived PowerShell sidecar (core/Invoke-DevKitRpc.ps1).
 * Every RPC method the sidecar knows about (see core/RpcMethods.ps1) is
 * called through here - adding a panel means adding a method there and a
 * call here, never a new Tauri command.
 */
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { recordRpcFailure } from "./errorCapture";

export class RpcClientError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RpcClientError";
  }
}

/**
 * The structured half of a sidecar RPC rejection, recovered from the flat
 * string the invoke boundary hands back. The sidecar answers a failed
 * method with `{ kind, message, detail? }`; HostError::Remote is built as
 * `Remote(err.kind, err.message)` and its Display renders
 * "sidecar returned an error: {KIND} ({message})" - KIND FIRST, message in
 * the trailing parentheses (crates/devkit-host/src/host.rs). That flat
 * string is what rpc_call's Result<T, String> rejection delivers here, so
 * this parses the kind back out (e.g. toolLaneBusy) for callers to branch
 * on. The message match is greedy up to the FINAL ")" so messages
 * containing parentheses round-trip. Anything that doesn't match (local
 * failures like timeouts and disconnects) comes back with a null kind and
 * the raw text as the message.
 */
export interface RpcRejection {
  kind: string | null;
  message: string;
  /** The exact rejection string, unparsed, for logging. */
  raw: string;
}

export function parseRpcError(err: unknown): RpcRejection {
  const raw = typeof err === "string" ? err : err instanceof Error ? err.message : String(err);
  const match = raw.match(/^sidecar returned an error: ([A-Za-z][\w]*) \(([\s\S]*)\)$/);
  if (match) return { kind: match[1], message: match[2], raw };
  return { kind: null, message: raw, raw };
}

export async function rpcCall<T>(method: string, params?: Record<string, unknown>): Promise<T> {
  try {
    return await invoke<T>("rpc_call", { method, params: params ?? null });
  } catch (err) {
    const failure = new RpcClientError(typeof err === "string" ? err : String(err));
    // Feeds the Error Center's "app" section. Deliberately fire-and-forget
    // and non-throwing (see lib/errorCapture.ts): the caller's rejection is
    // unchanged - same RpcClientError, same timing - so every existing
    // try/catch and react-query error path behaves exactly as before.
    recordRpcFailure(method, failure);
    throw failure;
  }
}

export async function sidecarStatus(): Promise<boolean> {
  return invoke<boolean>("sidecar_status");
}

/**
 * True when the whole app (and therefore the sidecar and every tool it
 * runs) is elevated - i.e. launched through Admin Mode's scheduled task
 * (tools/system/Set-DevKitAdminMode.ps1). Fixed for the process's lifetime.
 */
export async function isElevated(): Promise<boolean> {
  const result = await rpcCall<{ elevated: boolean }>("system.isElevated");
  return !!result?.elevated;
}

export async function sidecarRestart(): Promise<void> {
  return invoke<void>("sidecar_restart");
}

export async function toggleWindow(label: string): Promise<void> {
  return invoke<void>("toggle_window", { label });
}

export async function showWindow(label: string): Promise<void> {
  return invoke<void>("show_window", { label });
}

export interface DevKitRpcEvent {
  event: string;
  runId?: string;
  stream?: "stdout" | "stderr";
  line?: string;
  data?: unknown;
  [key: string]: unknown;
}

/**
 * What a `tool.run` call answers with once the tool has exited. The same
 * outcome also arrives as the `tool.finished` event, which is what the run
 * surfaces normally act on; this copy is the one that cannot be dropped
 * (see `droppedEventCount`).
 */
export interface ToolRunResult {
  runId: string;
  exitCode: number;
  cancelled: boolean;
}

/**
 * How long a run surface waits for `tool.finished` after the `tool.run`
 * call itself has answered, before it takes the outcome from that answer.
 * The event and the answer travel separately and either can arrive first;
 * the event is preferred because the last lines of output come with it.
 */
export const TOOL_RESULT_GRACE_MS = 1500;

/**
 * The number of events the app's forwarder had to drop, when `evt` is that
 * notice (`host.lagged`, emitted by app/src-tauri/src/lib.rs when a tool
 * produces output faster than it can be passed on), else null. The dropped
 * events are gone: output lines for certain, and possibly a run's
 * `tool.finished` - which is why a run surface also takes the outcome from
 * the `tool.run` answer (TOOL_RESULT_GRACE_MS).
 */
export function droppedEventCount(evt: DevKitRpcEvent): number | null {
  if (evt.event !== "host.lagged") return null;
  const data = evt.data as { dropped?: unknown } | null | undefined;
  const dropped = Number(data?.dropped);
  return Number.isFinite(dropped) && dropped > 0 ? Math.floor(dropped) : 0;
}

/** The line a run's console shows for dropped events. */
export function droppedEventsNote(dropped: number): string {
  const count = dropped > 0 ? `${dropped.toLocaleString("en-US")} ` : "";
  return `-- ${count}output event${dropped === 1 ? " was" : "s were"} dropped: the tool wrote faster than DevKit could show it. Some lines are missing here. --`;
}

/** Subscribes to every sidecar event (tool.started/output/finished, etc.). Call the returned fn to unsubscribe. */
export async function onDevKitEvent(handler: (evt: DevKitRpcEvent) => void): Promise<UnlistenFn> {
  return listen<DevKitRpcEvent>("devkit://event", (e) => handler(e.payload));
}

/** Subscribes to just one `runId`'s tool.started/output/finished events - used by the Control Center's tool runner. */
export function onToolRun(
  runId: string,
  handlers: {
    /** Fires when the sidecar confirms the child process exists (carries its pid). Never fires for a refused run. */
    onStarted?: (pid: number) => void;
    onOutput?: (stream: "stdout" | "stderr", line: string) => void;
    /** `cancelled` is the sidecar's own flag (tool.finished flattens `{exitCode, cancelled}`) - true when the run ended via tool.stop. */
    onFinished?: (exitCode: number, cancelled: boolean) => void;
    /** Events were dropped on the way here (see `droppedEventCount`). Not tied to a run: any of them may have been this run's. */
    onLagged?: (dropped: number) => void;
  },
): Promise<UnlistenFn> {
  return onDevKitEvent((evt) => {
    const dropped = droppedEventCount(evt);
    if (dropped !== null) {
      handlers.onLagged?.(dropped);
      return;
    }
    if (evt.runId !== runId) return;
    if (evt.event === "tool.started") {
      handlers.onStarted?.(Number(evt.pid ?? 0));
    } else if (evt.event === "tool.output" && evt.stream && evt.line !== undefined) {
      handlers.onOutput?.(evt.stream, evt.line);
    } else if (evt.event === "tool.finished") {
      handlers.onFinished?.(Number(evt.exitCode ?? -1), evt.cancelled === true);
    }
  });
}
