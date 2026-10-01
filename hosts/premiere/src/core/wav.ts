// WAV and raw PCM, on bytes in memory. Port of the WAV/PCM functions of
// hosts/resolve/src/higgs/util.lua, which work on files: here the caller
// reads and writes, and every function takes and returns a Uint8Array.
// Offsets are 0-based byte offsets into that array.

/** Boson generates at 24 kHz; matching it avoids a resample. */
export const PCM_RATE = 24000;
export const PCM_BITS = 16;
export const PCM_CHANNELS = 1;

export interface SampleStats {
  seconds: number;
  peak: number;
  rms: number;
  hot_ratio: number;
}

// 0.98 of full scale, matching recorder.HOT_PEAK.
const CLIP = 32112;

function pcmByteRate(): number {
  return PCM_RATE * PCM_CHANNELS * (PCM_BITS / 8);
}

function u16(b: Uint8Array, at: number): number {
  return b[at] + b[at + 1] * 256;
}

function u32(b: Uint8Array, at: number): number {
  return b[at] + b[at + 1] * 256 + b[at + 2] * 65536 + b[at + 3] * 16777216;
}

function put16(b: Uint8Array, at: number, v: number): void {
  b[at] = v % 256;
  b[at + 1] = Math.floor(v / 256) % 256;
}

function put32(b: Uint8Array, at: number, v: number): void {
  b[at] = v % 256;
  b[at + 1] = Math.floor(v / 256) % 256;
  b[at + 2] = Math.floor(v / 65536) % 256;
  b[at + 3] = Math.floor(v / 16777216) % 256;
}

function tag(b: Uint8Array, at: number): string {
  return String.fromCharCode(b[at], b[at + 1], b[at + 2], b[at + 3]);
}

function isRiffWave(b: Uint8Array, minLength: number): boolean {
  return b.length >= minLength && b.length >= 12 && tag(b, 0) === "RIFF" && tag(b, 8) === "WAVE";
}

function concat(parts: Uint8Array[]): Uint8Array {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

function ascii(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

function le32(v: number): Uint8Array {
  const out = new Uint8Array(4);
  put32(out, 0, v);
  return out;
}

/** Length of a PCM WAV in seconds from its header, or null for anything
 * else (compressed formats need a decoder to know). */
export function wavSeconds(wav: Uint8Array): number | null {
  if (!isRiffWave(wav, 12)) return null;
  let pos = 12;
  let byteRate: number | undefined;
  while (pos + 8 <= wav.length) {
    const id = tag(wav, pos);
    const size = u32(wav, pos + 4);
    pos += 8;
    if (id === "fmt ") {
      if (Math.min(size, wav.length - pos) < 12) break;
      byteRate = u32(wav, pos + 8);
      pos += size;
    } else if (id === "data") {
      if (byteRate !== undefined && byteRate > 0) return size / byteRate;
      return null;
    } else {
      pos += size + (size % 2);
    }
  }
  return null;
}

interface Chunks {
  fmt_at?: number;
  channels?: number;
  rate?: number;
  byte_rate?: number;
  block?: number;
  bits?: number;
  data_at: number;
  data_size: number;
}

/** Walk the chunks of a WAV, returning where fmt and data are. */
function wavChunks(all: Uint8Array): Chunks | null {
  if (!isRiffWave(all, 44)) return null;
  const out: Partial<Chunks> = {};
  let pos = 12;
  // As in the Lua: a chunk header with nothing after it ends the walk.
  while (pos + 9 <= all.length) {
    const id = tag(all, pos);
    const size = u32(all, pos + 4);
    if (id === "fmt ") {
      out.fmt_at = pos;
      out.channels = u16(all, pos + 10);
      out.rate = u32(all, pos + 12);
      out.byte_rate = u32(all, pos + 16);
      out.block = u16(all, pos + 20);
      out.bits = u16(all, pos + 22);
    } else if (id === "data") {
      out.data_at = pos;
      out.data_size = size;
      return out as Chunks;
    }
    pos += 8 + size + (size % 2);
  }
  return null;
}

/** Make a mono 16-bit PCM WAV two-channel, the same audio in both. An editor
 * lays a mono clip on one side of a stereo track; a real stereo file plays
 * centred everywhere. Returns the new file, or null for an already-stereo or
 * non-PCM file, which is left alone. */
export function wavToStereo(all: Uint8Array): Uint8Array | null {
  const c = wavChunks(all);
  if (!c || c.fmt_at === undefined || c.channels !== 1 || c.bits !== 16) return null;
  const data = all.subarray(c.data_at + 8, c.data_at + 8 + c.data_size);
  // Every 16-bit sample written twice: left and right carry the same audio.
  const pairs = Math.floor(data.length / 2);
  const stereo = new Uint8Array(pairs * 4 + (data.length % 2));
  for (let i = 0; i < pairs; i++) {
    const a = data[2 * i], b = data[2 * i + 1];
    stereo[4 * i] = a; stereo[4 * i + 1] = b; stereo[4 * i + 2] = a; stereo[4 * i + 3] = b;
  }
  if (data.length % 2 === 1) stereo[pairs * 4] = data[data.length - 1];
  const head = all.slice(0, c.data_at);
  put16(head, c.fmt_at + 10, 2);
  put32(head, c.fmt_at + 16, (c.byte_rate ?? 0) * 2);
  put16(head, c.fmt_at + 20, (c.block ?? 0) * 2);
  const tail = all.subarray(Math.min(all.length, c.data_at + 8 + c.data_size));
  return concat([ascii("RIFF"), le32(head.length + stereo.length + tail.length), head.subarray(8),
                 ascii("data"), le32(stereo.length), stereo, tail]);
}

/** Find fmt (PCM only when `pcmOnly`) and data the way wav_append_silence
 * and wav_slice do. */
function fmtAndData(all: Uint8Array, pcmOnly: boolean): { byteRate: number; block: number; dataAt: number; dataSize: number } | null {
  if (!isRiffWave(all, 44)) return null;
  let pos = 12;
  let byteRate: number | undefined, block: number | undefined, dataAt: number | undefined, dataSize = 0;
  while (pos + 9 <= all.length) {
    const id = tag(all, pos);
    const size = u32(all, pos + 4);
    if (id === "fmt ") {
      if (pcmOnly && u16(all, pos + 8) !== 1) return null;   // PCM only
      byteRate = u32(all, pos + 16);
      block = u16(all, pos + 20);
    } else if (id === "data") {
      dataAt = pos;
      dataSize = size;
      break;
    }
    pos += 8 + size + (size % 2);
  }
  if (byteRate === undefined || block === undefined || dataAt === undefined) return null;
  return { byteRate, block, dataAt, dataSize };
}

/** Append `seconds` of silence to a PCM WAV. Returns the new file (the same
 * array when there is less than a sample to add), or null for anything that
 * is not a plain PCM WAV. */
export function wavAppendSilence(all: Uint8Array, seconds: number): Uint8Array | null {
  if (!seconds || seconds <= 0) return null;
  const f = fmtAndData(all, true);
  if (!f) return null;
  const pad = Math.floor(f.byteRate * seconds / f.block) * f.block;
  if (pad <= 0) return all;
  return concat([ascii("RIFF"), le32(all.length - 8 + pad), all.subarray(8, f.dataAt + 4),
                 le32(f.dataSize + pad), all.subarray(f.dataAt + 8, f.dataAt + 8 + f.dataSize),
                 new Uint8Array(pad), all.subarray(Math.min(all.length, f.dataAt + 8 + f.dataSize))]);
}

/** The part of a PCM WAV from `fromSeconds` to the end, as a new WAV.
 * Seeking with a player that cannot seek: play the remainder instead. */
export function wavSlice(all: Uint8Array, fromSeconds?: number | null): Uint8Array | null {
  const f = fmtAndData(all, false);
  if (!f) return null;
  let skip = Math.floor(f.byteRate * Math.max(0, fromSeconds || 0) / f.block) * f.block;
  if (skip >= f.dataSize) skip = Math.max(0, f.dataSize - f.block);
  const rest = all.subarray(Math.min(all.length, f.dataAt + 8 + skip), f.dataAt + 8 + f.dataSize);
  return concat([ascii("RIFF"), le32(4 + (f.dataAt - 12) + 8 + rest.length), all.subarray(8, f.dataAt + 4),
                 le32(rest.length), rest]);
}

/** Seconds of audio in raw PCM of `size` bytes. */
export function pcmSeconds(size: number): number {
  return size / pcmByteRate();
}

/** Loudest sample in the last `window` seconds of raw PCM, as 0–1.
 * Reads only the tail, so it costs the same on a 3-second take as a 30-second
 * one and can be called on every tick of the UI loop. */
export function pcmPeak(pcm: Uint8Array, window?: number | null): number {
  const size = pcm.length;
  const want = Math.floor(pcmByteRate() * (window ?? 0.1));
  let from = Math.max(0, size - want);
  if (from % 2 === 1) from -= 1;   // never start mid-sample
  let peak = 0;
  for (let i = from; i + 1 < size; i += 2) {
    let v = pcm[i] + pcm[i + 1] * 256;
    if (v >= 32768) v -= 65536;
    if (v < 0) v = -v;
    if (v > peak) peak = v;
  }
  return peak / 32768;
}

/** Where the samples are in a PCM WAV: byte offset and length of `data`.
 * AVAudioRecorder writes a JUNK chunk before `fmt `, so nothing may assume
 * the samples start at byte 44. */
export function wavDataRange(wav: Uint8Array): { from: number; size: number } | null {
  if (!isRiffWave(wav, 12)) return null;
  let pos = 12;
  while (pos + 8 <= wav.length) {
    const id = tag(wav, pos);
    let size = u32(wav, pos + 4);
    if (id === "data") {
      const here = pos + 8;
      // A recorder killed mid-write leaves the length field at 0 or stale, so
      // trust the file rather than the header when the header claims more.
      const real = wav.length - here;
      if (size === 0 || size > real) size = Math.max(0, real);
      return { from: here, size };
    }
    pos = pos + 8 + size + (size % 2);
  }
  return null;
}

/** Peak, clipped-sample ratio and length over a span of 16-bit samples.
 * Shared by the raw-PCM and WAV paths so there is one loop to be right.
 * Seconds assume PCM_RATE mono, whatever the file says. */
function scanSamples(b: Uint8Array, from: number, count: number): SampleStats {
  const end = Math.min(b.length, from + Math.max(0, count));
  let peak = 0, hot = 0, total = 0, energy = 0;
  for (let i = from; i + 1 < end; i += 2) {
    let v = b[i] + b[i + 1] * 256;
    if (v >= 32768) v = 65536 - v;
    total += 1;
    if (v > peak) peak = v;
    if (v >= CLIP) hot += 1;
    // Squared in normalised units: 30 s of samples would overflow a double's
    // precision long before the end if summed as raw 16-bit squares.
    const n = v / 32768;
    energy += n * n;
  }
  return {
    seconds: total / PCM_RATE,
    peak: peak / 32768,
    // Average level, which is what "too quiet" really means: a single door
    // slam can put the peak where a whispered take's peak should be.
    rms: total > 0 ? Math.sqrt(energy / total) : 0,
    hot_ratio: total > 0 ? hot / total : 0,
  };
}

/** Stats over the samples of a PCM WAV, whatever chunks precede them. */
export function wavStats(wav: Uint8Array): SampleStats {
  const r = wavDataRange(wav);
  if (!r) return { seconds: 0, peak: 0, rms: 0, hot_ratio: 0 };
  return scanSamples(wav, r.from, r.size);
}

/** Peak, clipped-sample ratio and length over all of a raw PCM capture.
 * Called once, when a take ends — it reads every sample, which the tail-only
 * meter above deliberately does not. */
export function pcmStats(pcm: Uint8Array): SampleStats {
  return scanSamples(pcm, 0, pcm.length);
}

/** Wrap raw PCM in a WAV header.
 * `skipBytes` drops that much from the front, which is how the count-in is
 * thrown away: capture starts while "3… 2… 1…" is still on screen, so the
 * device is already open and warm by the time the user speaks.
 * Returns the file and its duration in seconds, or null if there was nothing
 * to wrap. */
export function pcmToWav(pcm: Uint8Array, skipBytes?: number | null): { wav: Uint8Array; seconds: number } | null {
  let skip = Math.floor(Number(skipBytes) || 0);
  if (skip < 0) skip = 0;
  if (skip % 2 === 1) skip -= 1;   // never start mid-sample
  let data = pcm.subarray(Math.min(skip, pcm.length));
  if (data.length < 2) return null;
  if (data.length % 2 === 1) data = data.subarray(0, data.length - 1);   // drop a half sample
  const block = PCM_CHANNELS * (PCM_BITS / 8);
  const head = new Uint8Array(44);
  head.set(ascii("RIFF"), 0);
  put32(head, 4, 36 + data.length);
  head.set(ascii("WAVEfmt "), 8);
  put32(head, 16, 16);
  put16(head, 20, 1);
  put16(head, 22, PCM_CHANNELS);
  put32(head, 24, PCM_RATE);
  put32(head, 28, PCM_RATE * block);
  put16(head, 32, block);
  put16(head, 34, PCM_BITS);
  head.set(ascii("data"), 36);
  put32(head, 40, data.length);
  return { wav: concat([head, data]), seconds: data.length / pcmByteRate() };
}
