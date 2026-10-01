// logrules.ts against the pure parts of the Resolve build's log.lua
// (shared/vectors/log.json).

import { test } from "node:test";
import { strict as assert } from "node:assert";
import { assertClose, loadVectors } from "./vectors.ts";
import * as L from "../src/core/logrules.ts";

const record = (v: unknown) => (Array.isArray(v) && v.length === 0 ? {} : v) as L.Fields;

const calls: Record<string, (input: any) => unknown> = {
  KEEP: () => L.KEEP,
  q: (i) => L.q(i.s),
  path_safe: (i) => L.pathSafe(i.p, i.home),
  fields: (i) => L.fields(record(i.t)),
  entry: (i) => ({ level: i.level, message: L.entry(i.message, i.t) }),
  metric: (i) => {
    const totals: L.Totals = { counts: {}, sums: {} };
    const lines = i.steps.map((s: any) => L.metric(totals, s.name, s.t));
    return { lines, counts: totals.counts, sums: totals.sums };
  },
  line: (i) => L.formatLine("00:00:00.000", i.level, i.message).slice(13) + "\n",
  logs_to_remove: (i) => L.logsToRemove(i.names),
  redact: (i) => L.redact(i.text),
};

for (const c of loadVectors("log")) {
  test(c.name, () => {
    const call = calls[c.fn];
    assert.ok(call, `no TypeScript call for ${c.fn}`);
    assertClose(call(c.input), c.expect);
  });
}

test("the stamp is local wall time to the millisecond", () => {
  const d = new Date(2026, 8, 30, 9, 5, 7);
  assert.equal(L.formatStamp(d.getTime() / 1000 + 0.042), "09:05:07.042");
});

test("file and header names use local time", () => {
  const d = new Date(2026, 8, 3, 4, 5, 6);
  assert.equal(L.logFileName(d), "higgs-vo-20260903-040506.log");
  assert.ok(L.isLogFileName(L.logFileName(d)));
  assert.equal(L.headerLine(d, "0000abcd"), "# Higgs VoiceOver log · 2026-09-03 04:05:06 · session 0000abcd");
});

test("warnings and errors are counted, and the summary carries the totals", () => {
  const totals: L.Totals = { counts: {}, sums: {} };
  L.countLevel(totals, "warn");
  L.countLevel(totals, "info");
  L.metric(totals, "speech", { ms: 10 });
  const s = L.summary(totals, 61.9);
  assert.equal(s.message, "session  log.warn=1 seconds=61 speech=1 speech.ms=10");
});

test("a session id is eight hex digits", () => {
  assert.equal(L.newSession(() => 0), "00000000");
  assert.match(L.newSession(), /^[0-9a-f]{8}$/);
});

test("Lua's number formatting", () => {
  assert.equal(L.luaNumber(1e15), "1e+15");
  assert.equal(L.luaNumber(1e14), "1e+14");
  assert.equal(L.luaNumber(123456789012345), "1.2345678901235e+14");
  assert.equal(L.luaNumber(0.1 + 0.2), "0.3");
  assert.equal(L.luaNumber(1e-5), "1e-05");
  assert.equal(L.luaNumber(10000000000000), "10000000000000");
  assert.equal(L.luaNumber(-2.5), "-2.5");
});
