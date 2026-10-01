// recorder.ts against the Resolve build's recorder.lua (shared/vectors/recorder.json).

import { test } from "node:test";
import { strict as assert } from "node:assert";
import { assertClose, loadVectors } from "./vectors.ts";
import * as R from "../src/core/recorder.ts";

const calls: Record<string, (input: any) => unknown> = {
  MIN_SECONDS: () => R.MIN_SECONDS,
  GOOD_MIN: () => R.GOOD_MIN,
  GOOD_MAX: () => R.GOOD_MAX,
  IDEAL: () => R.IDEAL,
  QUIET_RMS: () => R.QUIET_RMS,
  HOT_PEAK: () => R.HOT_PEAK,
  HOT_RATIO: () => R.HOT_RATIO,
  SLOW_WPS: () => R.SLOW_WPS,
  FAST_WPS: () => R.FAST_WPS,
  PASSAGES: () => R.PASSAGES,
  meter: (i) => R.meter(i.peak),
  word_count: (i) => R.wordCount(i.text),
  judge: (i) => R.judge(i.take, i.transcript),
  level_note: (i) => R.levelNote(i.peak) ?? undefined,
  coach: (i) => R.coach(i.seconds, i.limit),
};

for (const c of loadVectors("recorder")) {
  test(c.name, () => {
    const call = calls[c.fn];
    assert.ok(call, `no TypeScript call for ${c.fn}`);
    assertClose(call(c.input), c.expect);
  });
}

test("every passage reads in the target range at a natural pace", () => {
  for (const p of R.PASSAGES) {
    const secs = R.wordCount(p) / 2.8;
    assert.ok(secs > R.GOOD_MIN && secs < R.GOOD_MAX, `${secs}`);
  }
});
