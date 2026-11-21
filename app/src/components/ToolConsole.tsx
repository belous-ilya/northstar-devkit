import clsx from "clsx";
import { useStickToBottom } from "../hooks/useStickToBottom";
import "./ToolConsole.css";

export interface ToolConsoleLine {
  stream: string;
  line: string;
  /**
   * Stays with the line for as long as it is on screen (see
   * `nextConsoleLineId`). Optional: a finished run's stored transcript has
   * none, and never changes, so its position does the job.
   */
  id?: number;
}

let lineSequence = 0;

/**
 * An id for a line about to be shown in a LIVE console. A live console
 * drops its oldest lines once it is full; with the position as the React
 * key, every remaining line then "became" the one after it and all of them
 * were rewritten on each update. With an id that travels with the line,
 * only the lines that actually came or went are touched.
 */
export function nextConsoleLineId(): number {
  lineSequence += 1;
  return lineSequence;
}

interface ToolConsoleProps {
  lines: ToolConsoleLine[];
  className?: string;
}

/**
 * Scrolling monospace output pane for a streamed `tool.run` - the shared
 * visual/behavioral pattern (follows new output while the reader is at the
 * end, lets go when they scroll up; stderr tinted ember)
 * originally built for the Control Center's ToolRunDialog, factored out so
 * the widget's Quick Actions panel can show the same live console inline.
 * Renders nothing when there's no output yet, so callers can mount it
 * unconditionally.
 */
export function ToolConsole({ lines, className }: ToolConsoleProps) {
  const stick = useStickToBottom<HTMLDivElement>(lines);

  if (lines.length === 0) return null;

  return (
    <div className={clsx("tool-console", className)} {...stick}>
      {lines.map((l, i) => (
        <div key={l.id ?? i} className={l.stream === "stderr" ? "tool-console__line tool-console__line--err" : "tool-console__line"}>
          {l.line}
        </div>
      ))}
    </div>
  );
}
