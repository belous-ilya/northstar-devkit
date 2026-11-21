import { asArray } from "./arrays";
import type { Catalog } from "./types";

/**
 * Whether a recorded run's tool still ships with this DevKit.
 *
 * Run history outlives the tools it recorded: 4.8.0 removed about half the
 * catalog, and the rows for those tools still offered "Run again", which
 * could only answer "Tool script not found". Every script under `tools/` is
 * an entry in its folder's manifest, so the catalog is an exact record of
 * what can be run.
 *
 * Answers `true` (still offer it) whenever the catalog cannot say for
 * certain: it has not loaded, or a category's manifest failed to load - a
 * tool in a broken category is missing from the catalog but not from disk.
 */
export function toolStillShips(catalog: Catalog | undefined, folder: string, script: string): boolean {
  if (!catalog) return true;
  if (asArray(catalog.loadErrors).length > 0) return true;
  const wantedFolder = folder.toLowerCase();
  const wantedScript = script.toLowerCase();
  return asArray(catalog.modules).some(
    (m) =>
      m.folder.toLowerCase() === wantedFolder &&
      asArray(m.items).some((i) => i.script.toLowerCase() === wantedScript),
  );
}
