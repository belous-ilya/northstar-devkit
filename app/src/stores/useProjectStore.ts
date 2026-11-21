import { create } from "zustand";
import { rpcCall } from "../lib/ipc";
import { asArray } from "../lib/arrays";
import type { LinkedProject } from "../lib/types";

interface ProjectState {
  active: LinkedProject | null;
  linked: LinkedProject[];
  loading: boolean;
  /**
   * The last refresh could not reach the sidecar. `refresh` swallows its
   * error (callers are fire-and-forget), so without this an empty `linked`
   * after a failed first load is indistinguishable from "no projects linked
   * yet" - and nothing would know to try again.
   */
  loadFailed: boolean;
  refresh: () => Promise<void>;
  setActive: (id: string) => Promise<void>;
  /** Deselects the active project - the picker's explicit "None". */
  clearActive: () => Promise<void>;
  addProject: (path: string, name?: string) => Promise<void>;
}

export const useProjectStore = create<ProjectState>((set, get) => ({
  active: null,
  linked: [],
  loading: false,
  loadFailed: false,

  refresh: async () => {
    set({ loading: true });
    try {
      const [active, linked] = await Promise.all([
        rpcCall<LinkedProject | null>("projects.getActive"),
        rpcCall<LinkedProject[]>("projects.list"),
      ]);
      set({ active, linked: asArray(linked), loading: false, loadFailed: false });
    } catch {
      set({ loading: false, loadFailed: true });
    }
  },

  setActive: async (id: string) => {
    const active = await rpcCall<LinkedProject | null>("projects.setActive", { id });
    set({ active });
    await get().refresh();
  },

  /**
   * Drops the project scope so system/maintenance tools run unscoped. This
   * is a persisted state, not just a UI mode: projects.clearActive nulls
   * activeProjectId in the registry on disk, so None survives a restart the
   * same way picking a project does.
   *
   * It cannot go through setActive(""): the sidecar binds that id to
   * Set-DevKitActiveProject's Mandatory [string]$Id, which rejects an empty
   * string outright rather than treating it as "no project".
   */
  clearActive: async () => {
    await rpcCall<null>("projects.clearActive");
    set({ active: null });
    await get().refresh();
  },

  addProject: async (path: string, name?: string) => {
    await rpcCall<LinkedProject>("projects.add", { path, name });
    await get().refresh();
  },
}));
