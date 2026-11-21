import { useEffect } from "react";
import { rpcCall } from "../lib/ipc";
import type { ElevationTaskRepairResult } from "../lib/types";

/** Long enough after mount to stay out of startup; short enough to happen in any real session. */
const REPAIR_DELAY_MS = 20_000;

/**
 * Once per app start, asks the sidecar to bring the elevation scheduled task
 * up to the settings the app needs (system.repairElevationTask).
 *
 * Why this exists: DevKit is started through that task on every launch, and
 * tasks registered before this version carry Task Scheduler's defaults -
 * below-normal CPU, low disk I/O and low memory priority for the app and
 * everything it spawns, and "ignore" for a second launch. The registration
 * script now sets both correctly, but an install that merely updates keeps
 * the task it already has; this is what fixes those. The sidecar is elevated
 * (the app is admin-only), which editing the task requires, so there is no
 * prompt. A current task is left untouched, and the fix applies from the
 * next start.
 *
 * Call it from ONE place - WidgetApp, the always-on window. Fire-and-forget:
 * `absent` (a dev build has no task) and `failed` are ordinary answers, and a
 * sidecar that is not up yet simply means the next start tries again.
 */
export function useElevationTaskRepair(): void {
  useEffect(() => {
    const timer = window.setTimeout(() => {
      void rpcCall<ElevationTaskRepairResult>("system.repairElevationTask").catch(() => {});
    }, REPAIR_DELAY_MS);
    return () => window.clearTimeout(timer);
  }, []);
}
