// settings.ts against the pure parts of the Resolve build's config.lua
// (shared/vectors/settings.json).

import { test } from "node:test";
import { strict as assert } from "node:assert";
import { assertClose, loadVectors } from "./vectors.ts";
import * as S from "../src/core/settings.ts";
import { b64Encode } from "../src/core/base64.ts";

// Lua has one empty table where JSON has two: the vectors write it as [].
function emptyAsList(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(emptyAsList);
  if (v && typeof v === "object") {
    const keys = Object.keys(v);
    if (keys.length === 0) return [];
    return Object.fromEntries(keys.map((k) => [k, emptyAsList((v as Record<string, unknown>)[k])]));
  }
  return v;
}
const record = (v: unknown) => (Array.isArray(v) && v.length === 0 ? {} : structuredClone(v)) as any;

function parse(raw: string | undefined): { parsed: unknown; unreadable: boolean } {
  if (!raw) return { parsed: null, unreadable: false };
  try {
    const parsed = JSON.parse(raw);
    return { parsed, unreadable: !parsed || typeof parsed !== "object" || Array.isArray(parsed) };
  } catch {
    return { parsed: null, unreadable: true };
  }
}

const calls: Record<string, (input: any) => unknown> = {
  SCHEMA: () => S.SCHEMA,
  APP_NAME: () => S.APP_NAME,
  DEFAULTS: () => S.DEFAULTS,
  migrate: (i) => S.migrate(record(i.cfg), i.dirs),
  apply_defaults: (i) => S.applyDefaults(record(i.cfg), i.dirs.defaultOutputDir),
  load: (i) => {
    const { parsed, unreadable } = parse(i.raw);
    return { cfg: S.load(parsed, i.dirs), warned: unreadable, kept_bad: unreadable };
  },
  b64_decode: (i) => {
    const d = S.b64Decode(i.s);
    return d ? b64Encode(d) : undefined;
  },
  set_api_key: (i) => {
    const cfg: { api_key_b64?: string } = {};
    S.setApiKey(cfg, i.key);
    return cfg.api_key_b64;
  },
  get_api_key: (i) => S.getApiKey(record(i.cfg)),
  add_voice: (i) => {
    const cfg = record(i.cfg);
    const entry = S.addVoice(cfg, i.id, i.name, i.now);
    return { entry, cfg };
  },
  remove_voice: (i) => {
    const cfg = record(i.cfg);
    return { removed: S.removeVoice(cfg, i.id), cfg };
  },
  find_voice: (i) => S.findVoice(record(i.cfg), i.id) ?? undefined,
};

for (const c of loadVectors("settings")) {
  test(c.name, () => {
    const call = calls[c.fn];
    assert.ok(call, `no TypeScript call for ${c.fn}`);
    assertClose(emptyAsList(call(c.input)), c.expect);
  });
}

test("load without folders leaves the output folder for the caller", () => {
  assert.equal(S.load(null).output_dir, "");
  assert.equal(S.load({ schema: 5, output_dir: "/x" }).output_dir, "/x");
});

test("a key survives the round trip", () => {
  const cfg = S.load(null);
  S.setApiKey(cfg, "bai-fake-🙂");
  assert.equal(S.getApiKey(cfg), "bai-fake-🙂");
});
