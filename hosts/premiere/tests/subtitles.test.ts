// subtitles.ts against the Resolve build's subtitles.lua
// (shared/vectors/subtitles.json).

import { test } from "node:test";
import { strict as assert } from "node:assert";
import { assertClose, loadVectors } from "./vectors.ts";
import * as S from "../src/core/subtitles.ts";
import type { Cue, Take, Token } from "../src/core/subtitles.ts";

const clone = <T>(v: T): T => (v === undefined ? v : JSON.parse(JSON.stringify(v)));

const tokenOut = (t: Token) => ({ text: t.text, key: t.key, space: t.space, cjk: t.cjk, width: t.width, s: t.s, e: t.e, word: t.word });

/** ui.lua's place_subtitles, minus the timeline: split or whole per take,
 * offset to where it was placed, bounded by its clip, framed, written. */
function place(i: any): unknown {
  const { starts, ends, fps, mode, lead } = i;
  const origin = starts[0];
  const all: Cue[] = [];
  (clone(i.takes) as Take[]).forEach((take, k) => {
    let [cues, method] = S.forTake(take, mode) as [Cue[], string];
    if (method !== "words") cues = S.whole(take.text, (ends[k] - starts[k]) / fps);
    const offset = (starts[k] - origin) / fps;
    for (const cue of cues) {
      cue.start = cue.start + offset;
      cue.finish = cue.finish + offset;
      cue.bound = (ends[k] - origin) / fps;
      all.push(cue);
    }
  });
  const framed = S.frames(all, fps);
  const [srt, first] = S.srt(framed, fps, lead);
  return { cues: framed, srt, origin: first };
}

const calls: Record<string, (input: any) => unknown> = {
  constants: () => ({
    MODES: [...S.MODES], LIMIT: S.LIMIT, LIMIT_CJK: S.LIMIT_CJK, LIMIT_JA: S.LIMIT_JA, LIMIT_TH: S.LIMIT_TH,
    MIN_SECONDS: S.MIN_SECONDS, MAX_SECONDS: S.MAX_SECONDS, FILL_SECONDS: S.FILL_SECONDS, LAG_SECONDS: S.LAG_SECONDS,
  }),
  display_text: (i) => S.displayText(i.text),
  key_of: (i) => i.texts.map(S.keyOf),
  text_width: (i) => i.texts.map(S.textWidth),
  char_width: (i) => i.cps.map(S.charWidth),
  ending: (i) => i.texts.map((t: string) => S.ending(t) ?? false),
  tokenize: (i) => S.tokenize(i.text).map(tokenOut),
  align: (i) => {
    const tokens = S.tokenize(i.text);
    const method = S.align(tokens, clone(i.words), i.seconds);
    return { method, tokens: tokens.map(tokenOut) };
  },
  split: (i) => {
    const tokens = S.tokenize(S.displayText(i.text));
    S.align(tokens, clone(i.words), i.seconds);
    return S.split(tokens, i.mode);
  },
  for_take: (i) => {
    const [cues, method] = S.forTake(clone(i.take), i.mode);
    return { cues, method };
  },
  whole: (i) => S.whole(i.text, i.seconds),
  frames: (i) => S.frames(clone(i.cues), i.fps),
  srt: (i) => {
    const [text, origin] = S.srt(clone(i.cues), i.fps, i.lead);
    return { text, origin };
  },
  place,
  preview: (i) => S.preview(i.text, i.mode),
};

for (const c of loadVectors("subtitles")) {
  test(c.name, () => {
    const call = calls[c.fn];
    assert.ok(call, `no TypeScript call for ${c.fn}`);
    assertClose(call(c.input), c.expect);
  });
}
