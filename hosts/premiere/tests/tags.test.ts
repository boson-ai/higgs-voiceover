// tags.ts against the Resolve build's tags.lua (shared/vectors/tags.json).

import { test } from "node:test";
import { strict as assert } from "node:assert";
import { assertClose, loadVectors } from "./vectors.ts";
import * as T from "../src/core/tags.ts";

const calls: Record<string, (input: any) => unknown> = {
  EMOTIONS: () => T.EMOTIONS,
  STYLES: () => T.STYLES,
  SFX: () => T.SFX,
  SFX_WORDS: () => T.SFX_WORDS,
  SPEEDS: () => T.SPEEDS,
  PITCHES: () => T.PITCHES,
  EXPRESSIVENESS: () => T.EXPRESSIVENESS,
  PAUSES: () => T.PAUSES,
  MAX_CHARS: () => T.MAX_CHARS,
  categories: () => T.categories(),
  values_for: (i) => T.valuesFor(i.category),
  kind: (i) => T.kind(i.value) ?? undefined,
  token: (i) => T.token(i.value),
  terminate: (i) => T.terminate(i.text),
  place_tag: (i) => T.placeTag(i.before, i.after, i.value, i.line_start),
  compose: (i) => T.compose(i.text, i.direction),
  billable_length: (i) => T.billableLength(i.text, i.direction),
  has_leading_tag: (i) => T.hasLeadingTag(i.text),
};

for (const c of loadVectors("tags")) {
  test(c.name, () => {
    const call = calls[c.fn];
    assert.ok(call, `no TypeScript call for ${c.fn}`);
    assertClose(call(c.input), c.expect);
  });
}

test("the caret after a tag is a textarea index, not a byte offset", () => {
  const before = "旁白😀 ";
  const { text, caret } = T.placeTag(before, "x", "prosody:pause", false);
  assert.equal(text.slice(0, caret), before + "<|prosody:pause|> ");
});

test("terminate takes a different ceiling", () => {
  assert.equal(T.terminate("abc", 3), "abc");
  assert.equal(T.terminate("abc", 4), "abc.");
});
