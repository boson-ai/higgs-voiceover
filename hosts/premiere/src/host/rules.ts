// Timeline rules that need no Premiere, kept apart so they can be tested.

export interface Span { start: number; end: number }

/**
 * Where a run starts: the playhead, or — when clips on the track reach past
 * it — after the last of them, so nothing is overwritten. The same rule as
 * the Resolve build (gaps_after).
 */
export function startAfter(playhead: number, existing: Span[]): number {
  let cursor = playhead;
  for (const s of existing) cursor = Math.max(cursor, s.end);
  return cursor;
}
