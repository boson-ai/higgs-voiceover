// The microphone through Web Audio, for hosts whose panel is a real browser
// (CEP's Chromium, the browser preview). UXP has neither getUserMedia nor
// Web Audio, so the UXP build has no recorder.
//
// The input runs at whatever rate the device likes (44.1 or 48 kHz); takes
// are kept at 24 kHz mono 16-bit, the format the rest of the code — and the
// Resolve build's recorder rules — work in.

import type { Recorder } from "./host.ts";
import { PCM_RATE } from "../core/wav.ts";

export function createWebAudioRecorder(): Recorder {
  let stream: MediaStream | null = null;
  let ctx: AudioContext | null = null;
  let node: ScriptProcessorNode | null = null;
  let capturing = false;
  let chunks: Float32Array[] = [];
  let total = 0;
  let peak = 0;
  let rate = 48000;
  let deviceId = "default";

  function close() {
    capturing = false;
    try { node?.disconnect(); } catch { /* already gone */ }
    stream?.getTracks().forEach((t) => t.stop());
    void ctx?.close().catch(() => undefined);
    node = null; stream = null; ctx = null;
  }

  return {
    async inputs() {
      try {
        const list = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === "audioinput");
        // Chromium lists the default twice ("default" plus the device itself);
        // it is offered once, as "System default", which follows the system.
        const rest = list.filter((d) => d.deviceId !== "default" && d.deviceId !== "communications");
        return [
          { id: "default", label: "System default" },
          ...rest.map((d, i) => ({ id: d.deviceId, label: d.label || `Microphone ${i + 1}` })),
        ];
      } catch { return [{ id: "default", label: "System default" }]; }
    },
    use(id) { deviceId = id || "default"; },
    async open() {
      close();
      chunks = []; total = 0; peak = 0;
      try {
        // Raw voice: the browser's processing would colour the reference.
        const pick = deviceId === "default" ? {} : { deviceId: { exact: deviceId } };
        stream = await navigator.mediaDevices.getUserMedia({ audio: { ...pick, echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
      } catch (e) {
        return { ok: false, error: String((e as Error)?.name ?? e) };
      }
      ctx = new AudioContext();
      rate = ctx.sampleRate;
      const source = ctx.createMediaStreamSource(stream);
      // ScriptProcessor is old but present in every Chromium a panel runs in;
      // AudioWorklet needs a module URL, which file: panels make awkward.
      node = ctx.createScriptProcessor(4096, 1, 1);
      node.onaudioprocess = (ev) => {
        const data = ev.inputBuffer.getChannelData(0);
        for (let i = 0; i < data.length; i++) { const a = Math.abs(data[i]); if (a > peak) peak = a; }
        if (capturing) { chunks.push(new Float32Array(data)); total += data.length; }
      };
      source.connect(node);
      node.connect(ctx.destination);   // a processor only runs while connected
      return { ok: true };
    },
    begin() { chunks = []; total = 0; capturing = true; },
    level() { const p = peak; peak = 0; return Math.min(1, p); },
    seconds() { return total / rate; },
    async stop() {
      const got = chunks, n = total, from = rate;
      close();
      return n > 0 ? toPcm16(got, n, from) : null;
    },
    cancel() { close(); chunks = []; total = 0; },
  };
}

/** Float samples at `from` Hz → 24 kHz mono 16-bit little-endian, by linear interpolation. */
export function toPcm16(chunks: Float32Array[], count: number, from: number): Uint8Array {
  const all = new Float32Array(count);
  let at = 0;
  for (const c of chunks) { all.set(c.subarray(0, Math.min(c.length, count - at)), at); at += c.length; if (at >= count) break; }
  const out = Math.floor((count * PCM_RATE) / from);
  const bytes = new Uint8Array(out * 2);
  const step = from / PCM_RATE;
  for (let i = 0; i < out; i++) {
    const x = i * step, j = Math.floor(x), f = x - j;
    const a = all[j] ?? 0, b = all[j + 1] ?? a;
    const v = Math.max(-1, Math.min(1, a + (b - a) * f));
    const s = Math.round(v < 0 ? v * 32768 : v * 32767);
    bytes[i * 2] = s & 0xff;
    bytes[i * 2 + 1] = (s >> 8) & 0xff;
  }
  return bytes;
}
