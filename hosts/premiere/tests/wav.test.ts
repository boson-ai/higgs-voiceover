// wav.ts against the WAV/PCM helpers of the Resolve build's util.lua
// (shared/vectors/wav.json). Files travel as base64.

import { test } from "node:test";
import { strict as assert } from "node:assert";
import { assertClose, loadVectors } from "./vectors.ts";
import * as W from "../src/core/wav.ts";
import { b64Decode, b64Encode } from "../src/core/base64.ts";

const bytes = (s: string) => b64Decode(s);
const file = (b: Uint8Array | null) => (b ? b64Encode(b) : false);

const calls: Record<string, (input: any) => unknown> = {
  wav_seconds: (i) => W.wavSeconds(bytes(i.wav)) ?? undefined,
  wav_to_stereo: (i) => file(W.wavToStereo(bytes(i.wav))),
  wav_append_silence: (i) => file(W.wavAppendSilence(bytes(i.wav), i.seconds)),
  wav_slice: (i) => file(W.wavSlice(bytes(i.wav), i.from_seconds)),
  wav_data_range: (i) => W.wavDataRange(bytes(i.wav)) ?? undefined,
  wav_stats: (i) => W.wavStats(bytes(i.wav)),
  pcm_seconds: (i) => W.pcmSeconds(i.size),
  pcm_peak: (i) => W.pcmPeak(bytes(i.pcm), i.window),
  pcm_stats: (i) => W.pcmStats(bytes(i.pcm)),
  pcm_to_wav: (i) => {
    const r = W.pcmToWav(bytes(i.pcm), i.skip_bytes);
    return r ? { wav: b64Encode(r.wav), seconds: r.seconds } : undefined;
  },
  constants: () => ({ PCM_RATE: W.PCM_RATE, PCM_BITS: W.PCM_BITS, PCM_CHANNELS: W.PCM_CHANNELS }),
};

for (const c of loadVectors("wav")) {
  test(c.name, () => {
    const call = calls[c.fn];
    assert.ok(call, `no TypeScript call for ${c.fn}`);
    assertClose(call(c.input), c.expect);
  });
}

test("a wrapped capture reads back at the same length", () => {
  const pcm = new Uint8Array(24000 * 2 / 2);   // 0.5 s
  const r = W.pcmToWav(pcm)!;
  assert.equal(W.wavSeconds(r.wav), 0.5);
  assert.equal(W.wavStats(r.wav).seconds, 0.5);
  assert.deepEqual(W.wavDataRange(r.wav), { from: 44, size: pcm.length });
});

test("nothing to add returns the same file", () => {
  const r = W.pcmToWav(new Uint8Array(100))!;
  assert.equal(W.wavAppendSilence(r.wav, 0.00001), r.wav);
});
