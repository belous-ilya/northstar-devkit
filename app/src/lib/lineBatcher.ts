/**
 * Collects streamed console lines for a moment and hands them over
 * together.
 *
 * A tool's output arrives one line per event, and a chatty tool emits well
 * over a thousand lines a second. Acting on each line separately meant one
 * state update - one copy of the transcript, one render - per line. Run
 * surfaces push lines here instead and get them back in batches, at most
 * one per `delayMs`.
 *
 * Nothing is ever held back for longer than that, and nothing is lost:
 * `flush()` empties it on the spot (call it before anything that must come
 * after the lines already received - the final outcome, an error line) and
 * `take()` hands back what is pending without delivering it (for a caller
 * that wants to put those lines somewhere else).
 */
export interface LineBatcher<T> {
  push(line: T): void;
  /** Delivers whatever is pending now. Safe to call with nothing pending. */
  flush(): void;
  /** Returns what is pending and forgets it, without delivering it. */
  take(): T[];
}

export function createLineBatcher<T>(deliver: (lines: T[]) => void, delayMs: number): LineBatcher<T> {
  let pending: T[] = [];
  let timer: ReturnType<typeof setTimeout> | null = null;

  function take(): T[] {
    if (timer !== null) {
      clearTimeout(timer);
      timer = null;
    }
    const lines = pending;
    pending = [];
    return lines;
  }

  function flush(): void {
    const lines = take();
    if (lines.length > 0) deliver(lines);
  }

  return {
    push(line) {
      pending.push(line);
      if (timer === null) timer = setTimeout(flush, delayMs);
    },
    flush,
    take,
  };
}
