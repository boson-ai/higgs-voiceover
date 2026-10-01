// boson.ts and base64.ts against the Resolve build's api.lua and util.lua
// (shared/vectors/boson.json). Bytes travel as base64 or as lists of bytes.

import { test } from "node:test";
import { strict as assert } from "node:assert";
import { assertClose, loadVectors } from "./vectors.ts";
import * as B from "../src/core/boson.ts";
import { b64Decode, b64Encode, utf8Decode, utf8Encode } from "../src/core/base64.ts";

// What the Lua writes to a file comes back here as bytes: compare as base64.
function audioAsB64(res: any): any {
  if (!res || typeof res !== "object") return res;
  const out = { ...res };
  if (out.audio instanceof Uint8Array) out.audio = b64Encode(out.audio);
  return out;
}

const calls: Record<string, (input: any) => unknown> = {
  BASE_URL: () => B.BASE_URL,
  MODEL: () => B.MODEL,
  MAX_INPUT_CHARS: () => B.MAX_INPUT_CHARS,
  PRICE_PER_1K_CHARS: () => B.PRICE_PER_1K_CHARS,
  PRESET_VOICES: () => B.PRESET_VOICES,
  REF_MIN_SECONDS: () => B.REF_MIN_SECONDS,
  REF_MAX_SECONDS: () => B.REF_MAX_SECONDS,
  REF_MAX_BYTES: () => B.REF_MAX_BYTES,
  RETRY_DELAYS: () => B.RETRY_DELAYS,
  cost_for: (i) => B.costFor(i.chars),
  format_cost: (i) => B.formatCost(i.usd),
  short_url: (i) => B.shortUrl(i.url),
  is_preset: (i) => B.isPreset(i.id),
  voice_label: (i) => B.voiceLabel(i.voice, i.existing),
  friendly_error: (i) => B.friendlyError(i.code, i.raw),
  interpret: (i) => audioAsB64(B.interpret(i.code, i.body === undefined ? undefined : utf8Encode(i.body), i.err, i.expect)),
  unpack_timed: (i) => audioAsB64(B.unpackTimed(i.raw) ?? undefined),
  should_retry: (i) => B.shouldRetry(i.res, i.retries),
  speech: (i) => B.speechRequest(i),
  create_voice: (i) => {
    const audio = i.audio !== undefined ? b64Decode(i.audio) : i.audio_zeros !== undefined ? new Uint8Array(i.audio_zeros) : null;
    const r: any = B.createVoiceRequest({ name: i.name, ref_text: i.ref_text, audio });
    if (i.audio_zeros !== undefined && r.ok) {
      r.request.body.ref_audio = `<${r.request.body.ref_audio.length} base64 characters>`;
    }
    return r;
  },
  list_voices: () => ({ ok: true, request: B.listVoicesRequest() }),
  test: () => ({ ok: true, request: B.testRequest() }),
  test_outcome: (i) => B.testOutcome(i.res),
  transport: (i) => {
    const refused = B.checkKey(i.key, i.no_auth);
    if (refused) return { refused };
    const t = B.transportOptions(i.key, { noAuth: i.no_auth, hasBody: i.has_body, version: i.version });
    return { headers: t.headers, follow_redirects: t.followRedirects };
  },
  b64_encode: (i) => b64Encode(Uint8Array.from(i.bytes)),
  b64_decode: (i) => Array.from(b64Decode(i.s)),
};

for (const c of loadVectors("boson")) {
  test(c.name, () => {
    const call = calls[c.fn];
    assert.ok(call, `no TypeScript call for ${c.fn}`);
    assertClose(call(c.input), c.expect);
  });
}

test("utf8 round-trips every plane", () => {
  const s = "a é 你 😀 \u0000";
  assert.equal(utf8Decode(utf8Encode(s)), s);
  assert.deepEqual(Array.from(utf8Encode("é😀")), [0xc3, 0xa9, 0xf0, 0x9f, 0x98, 0x80]);
});

test("malformed utf8 becomes replacement characters", () => {
  assert.equal(utf8Decode(Uint8Array.from([0x61, 0xff, 0xe4, 0xbd])), "a���");
  assert.equal(utf8Encode("\ud800").length, 3);
});

test("the metric name of a request kind", () => {
  assert.equal(B.apiMetricName("create voice"), "api.create_voice");
  assert.equal(B.apiMetricName("speech"), "api.speech");
});

test("a byte cut never splits a character", () => {
  const long = "é".repeat(100);
  const msg = B.friendlyError("418", long);
  assert.equal(msg, "é".repeat(60));
});
