import type { LinkedProject } from "../../../lib/types";

/**
 * Pure rules for which folder the embedded terminal belongs in. Kept out of
 * TerminalPanel.tsx so they can be tested without a ConPTY or a DOM.
 */

/**
 * The folder a NEW terminal session should start in for this project:
 * the project's path, or `undefined` (the app's default folder) when no
 * project is selected or its folder no longer exists - spawning ConPTY in a
 * missing directory fails.
 */
export function sessionCwdFor(active: Pick<LinkedProject, "path" | "Missing"> | null): string | undefined {
  if (!active || active.Missing) return undefined;
  return active.path;
}

function canonical(path: string | undefined): string {
  if (!path) return "";
  // Windows paths: case-insensitive, either slash, trailing slash optional.
  return path.replace(/\//g, "\\").replace(/\\+$/, "").toLowerCase();
}

/** True when the running session sits in a different folder than the one a new session would start in. */
export function isSessionElsewhere(sessionCwd: string | undefined, activeCwd: string | undefined): boolean {
  return canonical(sessionCwd) !== canonical(activeCwd);
}

/** Last segment of a path, for a header that has no room for the whole thing. */
export function folderLabel(path: string | undefined): string {
  if (!path) return "the default folder";
  const trimmed = path.replace(/[\\/]+$/, "");
  const cut = Math.max(trimmed.lastIndexOf("\\"), trimmed.lastIndexOf("/"));
  const name = cut >= 0 ? trimmed.slice(cut + 1) : trimmed;
  return name || trimmed || "the default folder";
}
