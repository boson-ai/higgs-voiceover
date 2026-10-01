// text.ts against the Resolve build's util.lua (shared/vectors/text.json).

import { test } from "node:test";
import { strict as assert } from "node:assert";
import { assertClose, loadVectors } from "./vectors.ts";
import * as T from "../src/core/text.ts";

const calls: Record<string, (input: any) => unknown> = {
  trim: (i) => T.trim(i.s),
  strip_tags: (i) => T.stripTags(i.s),
  word_count: (i) => T.wordCount(i.s),
  estimate_seconds: (i) => T.estimateSeconds(i.s),
  split_lines: (i) => T.splitLines(i.text),
  split_sentences: (i) => T.splitSentences(i.text),
  is_ideographic: (i) => i.cps.map(T.isIdeographic),
  is_punct: (i) => i.cps.map(T.isPunct),
  clip_words: (i) => T.clipWords(i.text, i.count),
  sanitize: (i) => T.sanitize(i.name),
  utf8_len: (i) => T.utf8Len(i.s),
  utf8_chars: (i) => Array.from(T.utf8Chars(i.s), ([, ch]) => ch),
  utf8_codepoint: (i) => T.utf8Codepoint(i.s, i.index),
  format_clock: (i) => T.formatClock(i.seconds),
  format_duration: (i) => T.formatDuration(i.seconds),
};

for (const c of loadVectors("text")) {
  test(c.name, () => {
    const call = calls[c.fn];
    assert.ok(call, `no TypeScript call for ${c.fn}`);
    assertClose(call(c.input), c.expect);
  });
}

test("utf8Chars counts characters from 0", () => {
  assert.deepEqual([...T.utf8Chars("a😀b")], [[0, "a"], [1, "😀"], [2, "b"]]);
});

test("utf8Floor clamps to the string, every index being a boundary", () => {
  assert.equal(T.utf8Floor("旁白", -3), 0);
  assert.equal(T.utf8Floor("旁白", 1), 1);
  assert.equal(T.utf8Floor("旁白", 9), 2);
});

test("ids are unique and shaped like the Lua's", () => {
  const a = T.newId(), b = T.newId();
  assert.notEqual(a, b);
  assert.match(a, /^[0-9a-f]+[0-9a-f]{6}$/);
});

test("toNumber reads what Lua's tonumber reads", () => {
  assert.equal(T.toNumber(" 12.5 "), 12.5);
  assert.equal(T.toNumber("0x10"), 16);
  assert.equal(T.toNumber(""), undefined);
  assert.equal(T.toNumber("12a"), undefined);
  assert.equal(T.toNumber(null), undefined);
});
