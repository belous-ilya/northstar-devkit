import { create } from "zustand";

/**
 * The tool one palette selection asked to run. Carries enough to find the
 * catalog entry again on the receiving side (folder + script + key), plus
 * the label so a "that tool is gone" message can name it.
 *
 * `id` is the de-dupe key. Cross-window delivery emits the same request
 * twice on purpose (see CommandPalette.tsx) to survive a cold receiving
 * webview, so the store drops a repeat of the id it already handled.
 */
export interface PaletteToolRequest {
  id: string;
  folder: string;
  script: string;
  key: string;
  label: string;
}

/**
 * Tauri event carrying a PaletteToolRequest from the widget window to the
 * Control Center - the only window that can actually render a tool's run
 * dialog. Emitted with `emitTo("control-center", ...)`; ControlCenterApp
 * listens and feeds the payload straight into `requestTool` below.
 */
export const PALETTE_TOOL_EVENT = "devkit://palette-run-tool";

/**
 * Where a tool selection waits for a Control Center window that is still
 * starting. That window is created the first time it is opened (see
 * `window_or_create` in commands.rs), so the event above can be emitted
 * before anything in it is listening - and an event nobody hears is gone.
 * The widget therefore also leaves the request here, and the Control Center
 * picks it up when it mounts. Both windows are the same origin, so they
 * share localStorage.
 */
export const PALETTE_HANDOFF_KEY = "devkit:palette-tool-handoff";

/**
 * A handoff older than this is not a click the user is still waiting on -
 * it is a leftover (the window failed to open, the app was closed) and
 * opening a tool's run dialog for it later would be a surprise.
 */
export const PALETTE_HANDOFF_MAX_AGE_MS = 30_000;

type HandoffStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;

function defaultStorage(): HandoffStorage | null {
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

/** Leaves `request` for a Control Center window that may not be listening yet. Never throws. */
export function stashToolRequest(
  request: PaletteToolRequest,
  storage: HandoffStorage | null = defaultStorage(),
  now: number = Date.now(),
): void {
  try {
    storage?.setItem(PALETTE_HANDOFF_KEY, JSON.stringify({ at: now, request }));
  } catch {
    // Storage full or blocked: the event path is still tried.
  }
}

/** Forgets a waiting request - it was delivered some other way. Never throws. */
export function clearStashedToolRequest(storage: HandoffStorage | null = defaultStorage()): void {
  try {
    storage?.removeItem(PALETTE_HANDOFF_KEY);
  } catch {
    // Nothing to do.
  }
}

/**
 * Returns the waiting request, if there is a fresh one, and removes it so
 * it is acted on once. Anything unreadable, incomplete or too old is
 * removed and answered with null. Never throws.
 */
export function takeStashedToolRequest(
  storage: HandoffStorage | null = defaultStorage(),
  now: number = Date.now(),
): PaletteToolRequest | null {
  let raw: string | null = null;
  try {
    raw = storage?.getItem(PALETTE_HANDOFF_KEY) ?? null;
  } catch {
    return null;
  }
  if (raw === null) return null;
  clearStashedToolRequest(storage);
  try {
    const parsed = JSON.parse(raw) as { at?: unknown; request?: Partial<PaletteToolRequest> } | null;
    const request = parsed?.request;
    if (typeof parsed?.at !== "number" || !request) return null;
    const age = now - parsed.at;
    if (age < 0 || age > PALETTE_HANDOFF_MAX_AGE_MS) return null;
    const { id, folder, script, key, label } = request;
    if (
      typeof id !== "string" || !id ||
      typeof folder !== "string" ||
      typeof script !== "string" ||
      typeof key !== "string" ||
      typeof label !== "string"
    ) {
      return null;
    }
    return { id, folder, script, key, label };
  } catch {
    return null;
  }
}

/**
 * Tauri event asking the widget's gauges to bounce - the payload-free twin
 * of PALETTE_TOOL_EVENT, travelling the other way. The gauges only exist in
 * the widget window, so a `/dance` typed anywhere has to arrive as an event;
 * emitting to the widget's own label works even when the widget is the
 * window that asked, which keeps CommandPalette's two cases to one path.
 */
export const PALETTE_DANCE_EVENT = "devkit://palette-dance";

interface PaletteState {
  open: boolean;
  /** Pending tool selection awaiting a host that can open its run dialog. */
  toolRequest: PaletteToolRequest | null;
  /** Last id accepted by requestTool - makes duplicate deliveries idempotent. */
  lastRequestId: string | null;
  openPalette: () => void;
  closePalette: () => void;
  togglePalette: () => void;
  requestTool: (request: PaletteToolRequest) => void;
  clearToolRequest: () => void;
}

/**
 * Window-local palette state. Each Tauri window is its own webview with its
 * own module instances, so this store is per-window by construction - which
 * is exactly what's wanted: the palette is a per-window surface, and the
 * one thing that must cross windows (a tool selection made in the widget)
 * travels as a Tauri event instead.
 */
export const usePaletteStore = create<PaletteState>((set, get) => ({
  open: false,
  toolRequest: null,
  lastRequestId: null,

  openPalette: () => set({ open: true }),
  closePalette: () => set({ open: false }),
  togglePalette: () => set({ open: !get().open }),

  requestTool: (request) => {
    if (!request || !request.id || get().lastRequestId === request.id) return;
    set({ toolRequest: request, lastRequestId: request.id, open: false });
  },

  clearToolRequest: () => set({ toolRequest: null }),
}));
