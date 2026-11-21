import { useEffect, useRef } from "react";
import { useQuery, type UseQueryResult } from "@tanstack/react-query";
import { rpcCall } from "../lib/ipc";
import { useVisibility } from "./useVisibility";
import { usePollingSuspended } from "./usePollGate";

/**
 * Derived, panel-friendly view of a polled query's health.
 *
 * react-query's own flags are correct but easy to misread, and every panel
 * got it wrong the same way: they guarded on `isLoading && !data` and
 * rendered an empty/"n/a" state otherwise. In v5, once the initial fetch
 * fails (main.tsx sets retry: 1) `status` flips to "error", so `isLoading`
 * is false AND `data` is undefined - the "still loading" guard goes false
 * and the panel confidently renders "nothing here". With the sidecar down
 * that read as a healthy idle machine: four "n/a" gauges, "0 running", MCP
 * "not installed". The UI was lying.
 *
 * These four booleans make the honest states impossible to miss:
 *  - `pending`  - first load in flight, nothing to show YET  ("loading…")
 *  - `failed`   - last attempt failed and nothing ever loaded ("can't reach it")
 *  - `stale`    - data on screen, but the latest refresh failed (last known values)
 *  - `errorMessage` - what to actually tell the user
 *
 * Polling keeps running at full rate through an error, so every panel
 * self-heals the moment the sidecar returns. That is right for the sidecar,
 * whose outages are local and end abruptly - but wrong for a remote API that
 * rate-limits, where hammering a failing endpoint is the thing that keeps you
 * limited. Callers that poll through to GitHub pass `maxBackoffMs` to opt into
 * exponential backoff on consecutive failures; everyone else is unchanged.
 */
export interface PolledRpcStatus {
  /** First load still in flight with nothing rendered yet. Replaces the old `isLoading && !data` idiom. */
  pending: boolean;
  /** The most recent attempt failed AND no data has ever arrived - the panel has nothing true to show. */
  failed: boolean;
  /** Data is on screen but the latest refresh failed - what's rendered is last-known, not live. */
  stale: boolean;
  /** Human-readable text for the most recent failure; null while the last attempt succeeded. */
  errorMessage: string | null;
}

export type PolledRpcResult<T> = UseQueryResult<T> & PolledRpcStatus;

function describeRpcError(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  if (typeof error === "string" && error) return error;
  return "The DevKit sidecar did not respond.";
}

/**
 * Polls one RPC method on an interval, but only while the window is
 * visible (see useVisibility) - the metrics/node/git/mcp lanes on the
 * PowerShell side stay cheap, but there is no reason to even ask when
 * nobody's looking.
 *
 * `enabled` (default true) is the other half of that: pass `false` - most
 * callers compute it as `!!active` - when there's nothing to ask about yet
 * (no project selected). This is deliberately a separate flag rather than
 * inferred from `params === undefined`: several panels (Gauges, Node/Ports)
 * legitimately poll methods that take no params at all, and treating their
 * `undefined` as "disabled" would silently stop them polling forever.
 *
 * `unkeyedParams` are merged into the REQUEST but deliberately left out of
 * the query key - for params that tune how the backend answers without
 * changing WHAT is being asked. git.overview's `extraTips` is the case this
 * exists for: those are the open-PR head SHAs, and folding them into the key
 * meant every push to any open PR minted a fresh cache entry with no data,
 * flashing the whole pane back to its skeleton and turning the honest
 * "last known" stale state into a hard "can't reach it". Excluded from the
 * key, a change is simply picked up by the next poll (queryFn is rebuilt
 * every render, so it always closes over the latest value).
 *
 * `maxBackoffMs`, when given, caps an exponential slow-down applied while
 * consecutive fetches fail: intervalMs, then 2x, 4x, ... up to the cap, reset
 * to intervalMs by the first success. Omit it (the default) and the interval is
 * fixed, which is what every sidecar-backed panel wants. Pass it for methods
 * that reach a rate-limited third party - `github.prs` and `github.issues` are
 * the reason it exists.
 *
 * Returns the full UseQueryResult (unchanged for existing callers) plus the
 * PolledRpcStatus flags above - see that type for why panels should read
 * `failed`/`stale` rather than inferring health from `data` alone.
 */
export function usePolledRpc<T>(
  method: string,
  params: Record<string, unknown> | undefined,
  intervalMs: number,
  enabled = true,
  unkeyedParams?: Record<string, unknown>,
  maxBackoffMs?: number,
): PolledRpcResult<T> {
  // Two reasons to hold still: the window is hidden, or it is on screen with
  // nothing in it visible (the widget collapsed to its sliver - usePollGate).
  const windowVisible = useVisibility();
  const suspended = usePollingSuspended();
  const visible = windowVisible && !suspended;
  const query = useQuery({
    queryKey: [method, params ?? null],
    queryFn: () => rpcCall<T>(method, params && unkeyedParams ? { ...params, ...unkeyedParams } : params),
    enabled,
    refetchInterval: (query) => {
      if (!visible || !enabled) return false;
      if (maxBackoffMs === undefined) return intervalMs;
      // fetchFailureCount is reset to 0 on any success, so the ramp collapses
      // back to the base interval as soon as the endpoint answers again.
      const failures = query.state.fetchFailureCount;
      if (failures < 1) return intervalMs;
      return Math.min(intervalMs * 2 ** failures, maxBackoffMs);
    },
    // `visible` above is the one authority on whether to poll. Left at
    // false, react-query adds a second, private gate on document.hidden -
    // the very signal useVisibility documents as able to stick at "hidden"
    // in WebView2 after a window is created hidden and then shown. In that
    // state `visible` is true and every interval tick was silently skipped.
    // useVisibility still folds document.hidden in (minimize), so a truly
    // hidden window stops polling exactly as before.
    refetchIntervalInBackground: true,
    staleTime: intervalMs / 2,
  });

  // Coming back into view restarts the interval from zero, so without this
  // a panel shows its pre-hide data - as if live - for one whole interval
  // (20s for the GitHub lists, 60s for MCP) after the widget is summoned or
  // slid back out. Refetch once on the hidden -> visible edge when what is
  // on screen is older than a tick; fresh data is left alone.
  // (dataUpdatedAt is a dependency only so the comparison is never stale; a
  // run caused by fresh data finds `becameVisible` false and does nothing.)
  const { refetch, dataUpdatedAt } = query;
  const wasVisibleRef = useRef(visible);
  useEffect(() => {
    const becameVisible = visible && !wasVisibleRef.current;
    wasVisibleRef.current = visible;
    if (!becameVisible || !enabled) return;
    if (dataUpdatedAt > 0 && Date.now() - dataUpdatedAt > intervalMs) void refetch();
  }, [visible, enabled, intervalMs, refetch, dataUpdatedAt]);

  const hasData = query.data !== undefined;
  return {
    ...query,
    // `isLoading` (not `isPending`) on purpose: a disabled query sits in
    // status "pending" forever, and calling that "loading" would leave
    // project-scoped panels spinning with no project selected.
    pending: query.isLoading && !hasData,
    failed: query.isError && !hasData,
    stale: query.isError && hasData,
    errorMessage: query.isError ? describeRpcError(query.error) : null,
  };
}
