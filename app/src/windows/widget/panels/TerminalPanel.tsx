import { lazy, Suspense, useEffect, useState } from "react";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Button } from "../../../components/primitives/Button";
import { useProjectStore } from "../../../stores/useProjectStore";
import { ensureProjectsLoaded } from "../../../components/projects/ensureProjects";
import { folderLabel, isSessionElsewhere, sessionCwdFor } from "./terminalSession";
import { TerminalIcon } from "./icons";
import "./TerminalPanel.css";

// xterm is the largest dependency in the widget (about 290 kB of the
// bundle) and this panel sits behind a collapsed expander or an unopened
// tray, so most sessions never show it. Loading it on first open keeps it
// out of what the widget has to parse at startup.
const TerminalView = lazy(() =>
  import("../../../components/TerminalView").then((module) => ({ default: module.TerminalView })),
);

/**
 * Thin GlassPanel wrapper around TerminalView for the widget - a real
 * ConPTY `pwsh` session (src-tauri/src/terminal.rs), started in the active
 * project's folder when one is linked (terminalSession.ts holds the rules
 * for which folder, and for noticing the project changed since). This is the in-app replacement for
 * the old WPF widget's "launch an external Windows Terminal window"
 * flyout. Wired into WidgetApp.tsx inside a collapsed-by-default Expander
 * (a full ConPTY session in an always-on widget shouldn't claim vertical
 * space until asked for).
 *
 * Presentation notes: the panel clips to the glass radius (overflow
 * hidden in TerminalPanel.css) and the body has zero padding, so the
 * terminal's themed background runs edge-to-edge into the rounded
 * corners; TerminalView itself supplies the internal padding on that
 * background. Colors follow settings.preferences.terminalTheme
 * (lib/terminalThemes.ts) live - no respawn needed on theme change.
 */
export function TerminalPanel() {
  const active = useProjectStore((s) => s.active);
  const activeCwd = sessionCwdFor(active);

  // The session is NOT tied to the active project. It used to be: the
  // project's path was part of the React key, so picking another project in
  // the title bar unmounted the terminal - terminal_kill - and whatever was
  // running in it (a dev server, a build, a half-typed command) was gone
  // without a word. Now a session stays where it was started until the user
  // moves it, and the header says so when the two have drifted apart.
  //
  // `null` until the project list has loaded once: starting earlier would
  // open the session in the default folder and immediately show it as
  // "elsewhere" for anyone whose project simply had not arrived yet.
  const [session, setSession] = useState<{ cwd: string | undefined; nonce: number } | null>(null);
  useEffect(() => {
    let cancelled = false;
    void ensureProjectsLoaded().finally(() => {
      if (cancelled) return;
      setSession((current) => current ?? { cwd: sessionCwdFor(useProjectStore.getState().active), nonce: 0 });
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const elsewhere = session !== null && isSessionElsewhere(session.cwd, activeCwd);
  // One action for both buttons' meanings: a new session in the folder the
  // active project points at. `key` (below) turns the nonce into a clean
  // terminal_kill + terminal_spawn pair without TerminalView needing an
  // imperative restart API - it reads `cwd` once, at mount.
  const restartInActiveFolder = () => setSession((current) => ({ cwd: activeCwd, nonce: (current?.nonce ?? 0) + 1 }));
  const target = active && !active.Missing ? active.name : folderLabel(activeCwd);

  return (
    <GlassPanel className="terminal-panel" padded={false}>
      <div className="panel-header terminal-panel__header">
        <span className="panel-header__icon">
          <TerminalIcon />
        </span>
        <h2 className="panel-header__title">Terminal</h2>
        {elsewhere && (
          <span className="panel-header__hint" title={session?.cwd ?? "The app's default folder"}>
            in {folderLabel(session?.cwd)}
          </span>
        )}
        <div className="panel-header__actions">
          <Button
            size="sm"
            variant="ghost"
            onClick={restartInActiveFolder}
            disabled={session === null}
            title={
              elsewhere
                ? `Start a new session in ${target}. Whatever is running in this one stops.`
                : "Kill and restart the session"
            }
          >
            {elsewhere ? `Move to ${target}` : "Restart"}
          </Button>
        </div>
      </div>
      <div className="terminal-panel__body">
        <Suspense fallback={<div className="panel-empty">Starting terminal...</div>}>
          {session !== null && <TerminalView key={session.nonce} cwd={session.cwd} />}
        </Suspense>
      </div>
    </GlassPanel>
  );
}
