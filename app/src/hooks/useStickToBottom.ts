import { useCallback, useLayoutEffect, useRef, type RefObject } from "react";

/**
 * How close to the end still counts as "at the bottom". Wide enough that a
 * fractional scroll position or a half-visible last line does not count as
 * having scrolled away.
 */
export const STICK_SLACK_PX = 24;

/** True when a scroll container is showing its end (within `slack` pixels). */
export function isNearBottom(scrollTop: number, clientHeight: number, scrollHeight: number, slack = STICK_SLACK_PX): boolean {
  return scrollHeight - (scrollTop + clientHeight) <= slack;
}

/**
 * Keeps a growing output pane pinned to its newest line - but only while
 * the reader is already there.
 *
 * The consoles used to jump to the bottom on every update, which made it
 * impossible to read anything further up while a tool was still printing:
 * each new batch of lines threw the view back down. Now scrolling up lets
 * go, and scrolling back to the end takes hold again.
 *
 * Spread the result onto the scrolling element: `<div {...stick}>`. `dep`
 * is whatever changes when content is added (the lines array).
 */
export function useStickToBottom<T extends HTMLElement>(dep: unknown): {
  ref: RefObject<T | null>;
  onScroll: () => void;
} {
  const ref = useRef<T | null>(null);
  const stuck = useRef(true);

  const onScroll = useCallback(() => {
    const el = ref.current;
    if (el) stuck.current = isNearBottom(el.scrollTop, el.clientHeight, el.scrollHeight);
  }, []);

  // Layout effect, so the pane is already at its end when it is painted.
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) {
      // Not rendered (no output yet): the next pane starts at its end.
      stuck.current = true;
      return;
    }
    if (stuck.current) el.scrollTop = el.scrollHeight;
  }, [dep]);

  return { ref, onScroll };
}
