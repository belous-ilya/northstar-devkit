/**
 * One Escape closes one thing.
 *
 * Every modal here listens for Escape on `window`, and listeners on the same
 * target all run, in the order they were added. Without a rule, one key
 * press closed everything that was open: the Error Center disappeared from
 * under its own "Clear list?" confirm, Settings and the Project Manager
 * closed together when one was opened over the other.
 *
 * The rule: a surface acts on Escape only when nothing drawn above it is
 * open, and marks the key as handled (`preventDefault`) so nothing below it
 * acts as well. "Above" is the z-index order of the overlays' stylesheets,
 * recorded once, here.
 */

/** The modal overlays, lowest first - the same order their z-indexes put them in. */
export const OVERLAY_STACK = [
  { name: "toolRun", selector: ".tool-run-dialog__overlay" }, // 100
  { name: "projectManager", selector: ".project-manager__overlay" }, // 150
  { name: "errorCenter", selector: ".error-center__overlay" }, // 190
  { name: "confirm", selector: ".confirm-dialog__overlay" }, // 200
  { name: "update", selector: ".update-dialog__overlay" }, // 200
  { name: "settings", selector: ".settings-dialog__overlay" }, // 220
  { name: "palette", selector: ".command-palette__overlay" }, // 240
] as const;

export type OverlayName = (typeof OVERLAY_STACK)[number]["name"];

/** A selector matching every overlay drawn above `name`. Empty for the topmost. */
export function overlaysAbove(name: OverlayName): string {
  const index = OVERLAY_STACK.findIndex((o) => o.name === name);
  return OVERLAY_STACK.slice(index + 1)
    .map((o) => o.selector)
    .join(", ");
}

/**
 * True when the surface called `name` should act on this key press - and
 * then the press is marked handled. False for any other key, for a press
 * something else already handled, and while an overlay above is open.
 */
export function claimEscape(
  e: Pick<KeyboardEvent, "key" | "defaultPrevented" | "preventDefault">,
  name: OverlayName,
  root: Pick<Document, "querySelector"> = document,
): boolean {
  if (e.key !== "Escape" || e.defaultPrevented) return false;
  const above = overlaysAbove(name);
  if (above && root.querySelector(above)) return false;
  e.preventDefault();
  return true;
}
