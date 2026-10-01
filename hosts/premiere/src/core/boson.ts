// Boson AI Higgs TTS: endpoints, request bodies, and what a response means.
// Port of the pure parts of hosts/resolve/src/higgs/api.lua; sending the
// request (and the one-at-a-time queue around it) belongs to the host.
//
// Callers get a result record like the Lua's:
//   { ok, code, data?, audio?, words?, error? }
// where `audio` holds the bytes the Lua writes to a file instead.

import { b64Decode, b64Encode, utf8Decode, utf8Encode } from "./base64.ts";
import { luaNumber } from "./logrules.ts";

export const BASE_URL = "https://api.boson.ai/v1";
export const MODEL = "higgs-tts-3";

/** Hard limit from the API; the UI warns before a request would be rejected. */
export const MAX_INPUT_CHARS = 5000;

/** USD per 1,000 input characters. Generated audio is not billed separately. */
export const PRICE_PER_1K_CHARS = 0.015;

/** Preset voices. Descriptions are Boson's, trimmed to fit a menu. */
export const PRESET_VOICES: readonly { id: string; label: string }[] = [
  { id: "nora", label: "Nora — calm narrative (f)" },
  { id: "eleanor", label: "Eleanor — professional, educational (f)" },
  { id: "chloe", label: "Chloe — friendly, standard American (f)" },
  { id: "marcus", label: "Marcus — confident, professorial (m)" },
  { id: "oliver", label: "Oliver — thoughtful, reflective (m)" },
  { id: "jake", label: "Jake — energetic (m)" },
  { id: "default", label: "Default" },
];

/** Reference-audio limits for voice cloning, from the API docs. */
export const REF_MIN_SECONDS = 3;
export const REF_MAX_SECONDS = 30;
export const REF_MAX_BYTES = 10 * 1024 * 1024;

/** Waits (seconds) before retrying a request Boson answered "too many
 * requests" (429, not out of credit): three tries more, then the error goes
 * to the caller. A job backing off holds the queue, so lines still come back
 * in order. */
export const RETRY_DELAYS: readonly number[] = [2, 5, 10];

/** How a response body is read: JSON, speech audio, speech JSON with the
 * audio and word timings inside, or a file fetched from elsewhere. */
export type Expect = "json" | "binary" | "speech_json" | "file";

export interface Word {
  word: string;
  start: number;
  end: number;
}

export interface ApiRequest {
  method: "GET" | "POST";
  path: string;
  url: string;
  expect: Expect;
  label: string;
  /** Extra fields for the log line and metric. */
  meta?: Record<string, string | number>;
  body?: Record<string, unknown>;
}

export interface ApiResult {
  ok: boolean;
  code: string;
  data?: unknown;
  audio?: Uint8Array;
  words?: Word[];
  error?: string;
}

// ------------------------------------------------------------------ helpers

// Lua's %s: ASCII whitespace only.
const SPACE_RUN = /[ \t\n\v\f\r]+/g;

function trim(s: string): string {
  return s.replace(/^[ \t\n\v\f\r]+/, "").replace(/[ \t\n\v\f\r]+$/, "");
}

function asciiLower(s: string): string {
  return s.replace(/[A-Z]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 32));
}

// Lua's tostring() for what a decoded JSON value can be.
function str(v: unknown): string {
  return typeof v === "number" ? luaNumber(v) : String(v);
}

// Lua's `a or b`: only nil and false give way.
function or<T>(a: unknown, b: T): unknown {
  return a === undefined || a === null || a === false ? b : a;
}

// Lua's tonumber() for a JSON value: numbers and numeric strings.
function num(v: unknown): number | null {
  if (typeof v === "number") return v;
  if (typeof v === "string") {
    const s = trim(v);
    if (/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s)) return Number(s);
    if (/^0[xX][0-9a-fA-F]+$/.test(s)) return parseInt(s, 16);
  }
  return null;
}

/** The first `max` bytes of a string's UTF-8, never cutting a character
 * (the Lua cuts bytes, which can split one). */
function utf8Head(s: string, max: number): string {
  let bytes = 0;
  let i = 0;
  while (i < s.length) {
    const c = s.codePointAt(i)!;
    const n = c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
    if (bytes + n > max) break;
    bytes += n;
    i += c >= 0x10000 ? 2 : 1;
  }
  return s.slice(0, i);
}

function parseJson(raw: string): unknown {
  try {
    return JSON.parse(raw);
  } catch {
    return undefined;
  }
}

function text(body: Uint8Array | string | null | undefined): string {
  if (body === null || body === undefined) return "";
  return typeof body === "string" ? body : utf8Decode(body);
}

// --------------------------------------------------------------- estimating

/** Cost in USD for a number of billable characters. */
export function costFor(chars: unknown): number {
  return (num(chars) ?? 0) / 1000 * PRICE_PER_1K_CHARS;
}

export function formatCost(usd: number): string {
  if (usd < 0.01) return "$" + usd.toFixed(4);
  return "$" + usd.toFixed(2);
}

// ---------------------------------------------------------------- requests

/** Hosts and paths only, for the log: a query string could carry anything. */
export function shortUrl(url: unknown): string {
  return String(url ?? "").replace(/\?[\s\S]*$/, "");
}

/** The metric a request kind is counted under; the label names it. */
export function apiMetricName(label: unknown): string {
  return "api." + String(label).replace(SPACE_RUN, "_");
}

/** What a request needs besides its body. A Boson request carries the key
 * and never follows a redirect, so the key cannot be carried to another
 * server; public requests (the update check) never carry it and do follow
 * redirects (GitHub serves release files through one). */
export function transportOptions(key: string, opts: { noAuth?: boolean; hasBody?: boolean; version?: string } = {}): {
  headers: Record<string, string>;
  followRedirects: boolean;
} {
  const headers: Record<string, string> = { "User-Agent": "HiggsVoiceOver/" + (opts.version ?? "dev") };
  // Quotes and backslashes broke the Lua's curl config syntax; a real key
  // contains neither, so they are stripped here too.
  if (!opts.noAuth) headers["Authorization"] = "Bearer " + key.replace(/[\\"]/g, "");
  if (opts.hasBody) headers["Content-Type"] = "application/json";
  return { headers, followRedirects: !!opts.noAuth };
}

/** The answer when a Boson request is made without a key, or null to go
 * ahead. */
export function checkKey(key: string | null | undefined, noAuth = false): ApiResult | null {
  if ((key ?? "") === "" && !noAuth) {
    return { ok: false, code: "nokey", error: "Add your Boson API key in Settings first." };
  }
  return null;
}

function request(method: "GET" | "POST", path: string, expect: Expect, label: string,
                 extra: { meta?: ApiRequest["meta"]; body?: ApiRequest["body"] } = {}): ApiRequest {
  const r: ApiRequest = { method, path, url: BASE_URL + path, expect, label };
  if (extra.meta) r.meta = extra.meta;
  if (extra.body) r.body = extra.body;
  return r;
}

/** A built-in voice, whose id is safe to log; cloned ids are the user's. */
export function isPreset(id: unknown): boolean {
  return PRESET_VOICES.some((v) => v.id === id);
}

/** Generate speech. `text` must already have its direction tags composed in. */
export function speechRequest(spec: { text?: unknown; voice?: string; format?: string; timestamps?: boolean; label?: string }):
    { ok: true; request: ApiRequest } | ApiResult {
  const input = str(or(spec.text, ""));
  if (trim(input) === "") {
    return { ok: false, code: "", error: "Nothing to generate — this line is empty." };
  }
  let chars = 0;
  for (const _ of input) chars++;
  if (chars > MAX_INPUT_CHARS) {
    return { ok: false, code: "",
             error: `This line is ${chars} characters; the limit is ${MAX_INPUT_CHARS}. Break it into shorter lines.` };
  }
  const body: Record<string, unknown> = {
    model: MODEL,
    input,
    voice: spec.voice ?? "default",
    response_format: spec.format ?? "wav",
  };
  // Word timings for subtitles. Boson then answers in JSON, and skips its
  // text normalisation for the request (numbers and dates are read as
  // written), so they are asked for only when subtitles are wanted.
  if (spec.timestamps) body.timestamps = true;
  return {
    ok: true,
    request: request("POST", "/audio/speech", spec.timestamps ? "speech_json" : "binary", spec.label ?? "speech", {
      meta: { chars, voice: isPreset(spec.voice) ? String(spec.voice) : "cloned",
              format: spec.format ?? "wav", timestamps: spec.timestamps ? 1 : 0 },
      body,
    }),
  };
}

export function listVoicesRequest(): ApiRequest {
  return request("GET", "/audio/voices", "json", "list voices");
}

/** Cheapest call that proves the key works; read its result with testOutcome(). */
export function testRequest(): ApiRequest {
  return request("GET", "/audio/voices", "json", "test connection");
}

/** The voices in a list response, whichever envelope it came in. */
export function voiceList(data: unknown): unknown[] {
  if (!data || typeof data !== "object") return [];
  const d = data as Record<string, unknown>;
  const list = or(d.data, or(d.voices, d));
  return Array.isArray(list) ? list : [];
}

export function testOutcome(res: ApiResult): { ok: true; voices: number } | { ok: false; error?: string; code: string } {
  if (res.ok) return { ok: true, voices: voiceList(res.data).length };
  return { ok: false, error: res.error, code: res.code };
}

/** Register a cloned voice from a reference recording.
 * Voice ids are deterministic per (key, audio), so re-submitting the same clip
 * returns the same id rather than creating a duplicate. */
export function createVoiceRequest(spec: { name?: string; ref_text?: string; audio?: Uint8Array | null }):
    { ok: true; request: ApiRequest } | ApiResult {
  const audio = spec.audio;
  if (!audio) return { ok: false, code: "", error: "Could not read the reference recording." };
  if (audio.length > REF_MAX_BYTES) {
    return { ok: false, code: "",
             error: `The reference is ${(audio.length / 1048576).toFixed(1)} MB; the limit is ${Math.trunc(REF_MAX_BYTES / 1048576)} MB.` };
  }
  return {
    ok: true,
    request: request("POST", "/audio/voices", "json", "create voice", {
      body: {
        // Boson's voice object has no `name`: the label is `description`, and
        // it is what the list endpoint gives back. (Sending `name` was silently
        // ignored, so voices came back from Refresh as bare ids.)
        description: spec.name ?? "Voice",
        ref_audio: b64Encode(audio),
        // Boson's create-voice takes a transcript but only enforces one
        // character, so leaving it out is a supported way to clone. A single
        // stop is the honest stand-in for "no words given" — inventing text
        // that does not match the audio is worse than giving none, because the
        // model is conditioned on the pair.
        ref_text: trim(spec.ref_text ?? "") !== "" ? spec.ref_text : ".",
      },
    }),
  };
}

/** The name to show for a voice from the list endpoint: its description if
 * it has one; otherwise the name already given to it on this machine;
 * otherwise when it was made — never the raw `voice_<sha256>` id. */
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
export function voiceLabel(v: Record<string, unknown>, existing?: string | null): string {
  const d = trim(str(or(v.description, or(v.name, ""))));
  if (d !== "") return d;
  if (existing && !existing.startsWith("voice_")) return existing;
  const m = /^(\d{4})-(\d\d)-(\d\d)/.exec(str(or(v.created_at, "")));
  if (m) return `Cloned voice · ${MONTHS[Number(m[2]) - 1] ?? m[2]} ${Number(m[3])}, ${m[1]}`;
  return "Cloned voice";
}

// ---------------------------------------------------------------- responses

/** Turn a failure into one short sentence: what happened, then what to do.
 * Boson's own wording is only used when it names something specific we
 * cannot infer (a bad parameter, say), trimmed to one line. `code` is the
 * HTTP status as text, "" when no answer came back at all. */
export function friendlyError(code: string, raw: unknown): string {
  const low = asciiLower(str(or(raw, "")));
  const mentions = (...words: string[]) => words.some((w) => low.includes(w));
  const detail = () => utf8Head(str(or(raw, "")).replace(SPACE_RUN, " "), 120);

  if (code === "") {
    if (mentions("timed out", "timeout", "operation too slow")) {
      return "Boson took too long to answer. Try again.";
    }
    return "Couldn't reach Boson. Check your internet connection.";
  } else if (code === "401") {
    return "That API key was rejected. Check it in Settings.";
  } else if (code === "403") {
    if (mentions("credit", "quota", "billing", "balance")) {
      return "Your Boson account is out of credit. Top up at boson.ai.";
    }
    return "This key can't use Higgs TTS. Check your plan at boson.ai.";
  } else if (code === "404") {
    if (mentions("voice")) return "That voice is no longer on your account. Pick another voice.";
    return "Boson couldn't find what the request asked for.";
  } else if (code === "413") {
    return "That line is too long for one request. Break it into shorter lines.";
  } else if (code === "429") {
    if (mentions("credit", "quota", "billing", "balance", "insufficient")) {
      return "Your Boson account is out of credit. Top up at boson.ai.";
    }
    return "Too many requests at once. Wait a few seconds and try again.";
  } else if (code === "400" || code === "422") {
    if (mentions("voice")) return "Boson didn't accept that voice. Pick another voice.";
    const d = detail();
    if (d !== "") return "Boson rejected the request: " + d;
    return "Boson rejected the request.";
  } else if (code.startsWith("5")) {
    return "Boson's service is having trouble. Try again in a moment.";
  }
  const d = detail();
  return d !== "" ? d : "Boson returned an unexpected response (" + code + ").";
}

/** Split a timestamped speech response into its audio bytes and its word
 * list ({ word, start, end } in seconds, or undefined when Boson could not
 * align the line). The base64 audio is cut out by position rather than
 * handed to the JSON parser — a minute of wav is several megabytes of it.
 * Null when there is no audio field. */
export function unpackTimed(raw: unknown): { audio: Uint8Array; words?: Word[] } | null {
  const s = String(raw ?? "");
  const open = /"audio"[ \t\n\v\f\r]*:[ \t\n\v\f\r]*"/.exec(s);
  if (!open) return null;
  const openAt = open.index + open[0].length;           // first character of the base64
  const closeAt = s.indexOf('"', openAt);
  if (closeAt < 0) return null;
  const b64 = s.slice(openAt, closeAt).replace(/\\\//g, "/");
  const data = parseJson(s.slice(0, openAt) + s.slice(closeAt));
  let words: Word[] | undefined;
  const ts = data && typeof data === "object" ? (data as Record<string, unknown>).timestamps : undefined;
  if (Array.isArray(ts) && ts.length > 0) {
    words = [];
    for (const w of ts) {
      if (!w || typeof w !== "object") continue;
      const r = w as Record<string, unknown>;
      const start = num(r.start), end = num(r.end);
      if (start !== null && end !== null && r.word !== undefined && r.word !== null && r.word !== false) {
        words.push({ word: str(r.word), start, end });
      }
    }
    if (words.length === 0) words = undefined;
  }
  const out: { audio: Uint8Array; words?: Word[] } = { audio: b64Decode(b64) };
  if (words) out.words = words;
  return out;
}

/** What a finished request means. `code` is the HTTP status as text ("" or
 * "000" when no answer came back at all — no network, DNS, refused, timed
 * out); `errText` is the transport's own error, which tells a timeout from
 * no connection. */
export function interpret(code: string, body: Uint8Array | string | null | undefined, errText: string, expect: Expect): ApiResult {
  let c = String(code ?? "").replace(SPACE_RUN, "");
  const err = String(errText ?? "").replace(/[ \t\n\v\f\r]+$/, "");
  if (c === "000") c = "";

  if (c === "") return { ok: false, code: "", error: friendlyError("", err) };

  if (c === "200" || c === "201") {
    if (expect === "json") {
      const data = parseJson(text(body));
      if (!data || typeof data !== "object") {
        return { ok: false, code: c, error: "Boson sent a response Higgs VoiceOver couldn't read." };
      }
      return { ok: true, code: c, data };
    }
    if (expect === "speech_json") {
      // Timestamps turn the response into JSON with the audio inside it.
      const timed = unpackTimed(text(body));
      if (!timed || timed.audio.length === 0) {
        return { ok: false, code: c, error: "Boson returned no audio for that line." };
      }
      const res: ApiResult = { ok: true, code: c, audio: timed.audio };
      if (timed.words) res.words = timed.words;
      return res;
    }
    // Binary payload: the audio itself.
    const audio = typeof body === "string" ? utf8Encode(body) : body;
    if (!audio || audio.length === 0) {
      return { ok: false, code: c, error: "Boson returned no audio for that line." };
    }
    return { ok: true, code: c, audio };
  }

  // Error response: the body is JSON in every documented failure case.
  const raw = text(body);
  const parsed = parseJson(raw);
  let msg: unknown;
  if (parsed && typeof parsed === "object") {
    const p = parsed as Record<string, unknown>;
    if (p.error && typeof p.error === "object") msg = (p.error as Record<string, unknown>).message;
    else if (typeof p.error === "string") msg = p.error;
    else msg = p.message;
  }
  if (msg === undefined || msg === null || msg === false || msg === "") msg = trim(utf8Head(raw, 300));
  return { ok: false, code: c, error: friendlyError(c, msg) };
}

/** Should a failed request be tried again, after RETRY_DELAYS[retries]? Only
 * "too many requests" that is not about credit, three times at most. */
export function shouldRetry(res: ApiResult, retries = 0): boolean {
  if (res.ok || res.code !== "429") return false;
  if (String(res.error).includes("credit")) return false;
  return retries < RETRY_DELAYS.length;
}
