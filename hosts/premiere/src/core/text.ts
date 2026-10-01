// Shared text helpers: segmentation, clip names, filenames, clocks, ids.
//
// Ported from the Resolve build's util.lua (its text, utf8 and id parts).
// Nothing here knows about Premiere, the Boson API, or the UI.
//
// Lua counts bytes; this port counts characters (Unicode code points) wherever
// a position or a length is exposed — `utf8Len`, `utf8Chars`, `utf8Floor`,
// `utf8Codepoint` take and return code-point indices, 0-based. JavaScript's
// own string indices are UTF-16 units, so they are not used for positions.
// Only `sanitize` still measures bytes, because a filename's limit is in bytes.
//
// Lua's `%s` is ASCII whitespace (space, \t, \n, \v, \f, \r); JavaScript's `\s`
// also matches no-break and ideographic spaces, so it is spelled out here.

const WS = "[ \\t\\n\\v\\f\\r]";
const LEADING_WS = new RegExp(`^${WS}+`);
const TRAILING_WS = new RegExp(`${WS}+$`);
const WS_RUN = new RegExp(`${WS}+`, "g");
const NON_WS_RUN = /[^ \t\n\v\f\r]+/g;

/** Lua's `tonumber` for the values a host passes: numbers as they are,
 * numeric strings parsed, anything else undefined. */
export function toNumber(v: unknown): number | undefined {
  if (typeof v === "number") return v;
  if (typeof v !== "string") return undefined;
  const t = trim(v);
  if (/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(t)) return Number(t);
  if (/^0[xX][0-9a-fA-F]+$/.test(t)) return parseInt(t, 16);
  return undefined;
}

// ---------------------------------------------------------------------- text

export function trim(s: string): string {
  return String(s).replace(LEADING_WS, "").replace(TRAILING_WS, "");
}

/** Strip inline control tags, leaving only spoken words.
 * Character counts are billed on the full input, but the user reasons about the
 * words, so both counts exist and callers pick the right one. */
export function stripTags(s: string): string {
  return String(s).replace(/<\|[\s\S]*?\|>/g, "");
}

export function wordCount(s: string): number {
  return (stripTags(s).match(NON_WS_RUN) ?? []).length;
}

/** Rough spoken duration, for estimates before a take exists.
 * 150 wpm is a common narration pace; this is a hint in the UI, never a value
 * anything downstream depends on. */
export function estimateSeconds(s: string): number {
  return wordCount(s) / 150 * 60;
}

/** Split a script into segments on line breaks.
 *
 * Line breaks are the only delimiter, deliberately. The TTS service handles
 * long input itself, so there is no reason to guess at sentence boundaries or
 * chunk sizes here — a script with no line breaks is one segment and one
 * request. Writers already break their scripts where the beats are, and that
 * is a better signal than anything inferred.
 *
 * Blank lines collapse rather than producing empty segments, so text separated
 * by single or double line breaks both behave the way it looks. */
export function splitLines(text: string): string[] {
  const out: string[] = [];
  for (const raw of String(text).split("\n")) {
    const line = trim(raw);
    if (line !== "") out.push(line);
  }
  return out;
}

/** Split one segment into sentences, for users who want finer control.
 * Abbreviations are not handled; splitting is a user-visible action they can
 * undo by merging, so a wrong guess is cheap. */
export function splitSentences(text: string): string[] {
  const out: string[] = [];
  const body = trim(text) + " ";
  const re = /([\s\S]*?[.?!]+["')\]]*)[ \t\n\v\f\r]+/g;
  for (let m = re.exec(body); m; m = re.exec(body)) {
    const piece = trim(m[1]);
    if (piece !== "") out.push(piece);
  }
  // The tail is cut where the joined pieces end, counted in characters as Lua
  // counts bytes; like the Lua, a run of spaces between sentences shifts it.
  const consumed = out.join(" ");
  const rest = trim(Array.from(trim(text)).slice(utf8Len(consumed)).join(""));
  if (rest !== "") out.push(rest);
  if (out.length === 0) out.push(trim(text));
  return out;
}

/** Does this codepoint belong to a script that writes without spaces?
 * Chinese, Japanese kana and Thai run words together, so a "word" cannot be
 * found by splitting on spaces and each character has to count for itself.
 * Cyrillic, Greek, Arabic, Hebrew and Hangul all use spaces and are words like
 * any other — the test is the script, not whether the bytes are multi-byte. */
export function isIdeographic(cp: number): boolean {
  return (cp >= 0x3040 && cp <= 0x30FF)     // hiragana, katakana
      || (cp >= 0x3400 && cp <= 0x4DBF)     // CJK extension A
      || (cp >= 0x4E00 && cp <= 0x9FFF)     // CJK unified ideographs
      || (cp >= 0xF900 && cp <= 0xFAFF)     // CJK compatibility
      || (cp >= 0xFF66 && cp <= 0xFF9D)     // half-width katakana
      || (cp >= 0x0E00 && cp <= 0x0E7F);    // Thai
}

/** Is this codepoint punctuation rather than a letter?
 * Covers ASCII punctuation and the full-width and CJK marks that sit between
 * characters in Chinese and Japanese — 。、，！？「」and the rest. */
export function isPunct(cp: number): boolean {
  if (cp === 39) return false;              // an apostrophe is inside a word
  if (cp < 128) {
    return !(cp >= 48 && cp <= 57)
        && !(cp >= 65 && cp <= 90)
        && !(cp >= 97 && cp <= 122);
  }
  return (cp >= 0x2000 && cp <= 0x206F)     // general punctuation
      || (cp >= 0x3000 && cp <= 0x303F)     // CJK symbols and punctuation
      || (cp >= 0xFF00 && cp <= 0xFF0F)     // full-width ASCII punctuation
      || (cp >= 0xFF1A && cp <= 0xFF20)
      || (cp >= 0xFF3B && cp <= 0xFF40)
      || (cp >= 0xFF5B && cp <= 0xFF65);
}

/** The opening of a line, for a clip or file name:
 * "Welcome back to the channel!" → "Welcome_back_to_the".
 * Scripts that separate words with spaces give up whole words. Scripts that do
 * not — Chinese, Japanese, Thai — have no words to give, so their characters
 * count as half a word each: four English words and eight Chinese characters
 * carry about the same amount of a sentence, and naming every clip after one
 * syllable helps nobody. A line that mixes the two spends one budget across
 * both, so "iPhone 拍摄的日落" does not get filed as "iPhone". */
export function clipWords(text: string | null | undefined, count?: number | null): string {
  const budget = count ?? 4;
  const clean = stripTags(String(text ?? ""));
  const parts: string[] = [];
  let used = 0;
  let word: string[] = [];

  const flush = (): void => {
    if (word.length > 0) {
      // "It's" is one word and reads better in a filename without the mark.
      const w = word.join("").replace(/'/g, "");
      word = [];
      if (w !== "") {
        parts.push(w);
        used += 1;
      }
    }
  };

  for (const ch of clean) {
    if (used >= budget) break;
    const cp = ch.codePointAt(0)!;
    if (isPunct(cp)) {
      flush();                              // a space or a mark ends a word
    } else if (isIdeographic(cp)) {
      flush();
      parts.push(ch);                       // one character, half a word
      used += 0.5;
    } else {
      word.push(ch);                        // a letter in a spaced script
    }
  }
  flush();

  if (parts.length === 0) return "take";
  // Characters run together; words are separated. A single ideographic
  // character is a `part` of one character, which is how they are told apart.
  const isCharPart = (x: string): boolean => utf8Len(x) === 1 && isIdeographic(x.codePointAt(0)!);
  let out = parts[0];
  for (let i = 1; i < parts.length; i++) {
    const sep = (isCharPart(parts[i - 1]) || isCharPart(parts[i])) ? "" : "_";
    out = out + sep + parts[i];
  }
  return out;
}

/** Make a string safe for use as a filename component.
 * Keep everything except what a filesystem actually refuses: modern
 * filesystems store filenames as Unicode, so Chinese, Japanese, Korean,
 * Cyrillic, Greek and accented characters all stay. */
export function sanitize(name: unknown): string {
  let s = String(name ?? "");
  // Characters any common filesystem refuses (clips may sit on shared or
  // external drives, not only APFS), plus control characters.
  s = s.replace(/[<>:"/\\|?*]/g, "").replace(/[\x00-\x1f\x7f]/g, "");
  s = s.replace(WS_RUN, "_").replace(/_+/g, "_");
  // Some filesystems also refuse a trailing dot or space.
  s = s.replace(/^[._]+/, "").replace(/[._]+$/, "");
  // At most 48 bytes of UTF-8, cut on a character boundary.
  if (utf8ByteLength(s) > 48) {
    let bytes = 0;
    let cut = "";
    for (const ch of s) {
      bytes += utf8ByteLength(ch);
      if (bytes > 48) break;
      cut += ch;
    }
    s = cut;
  }
  return s;
}

// ---------------------------------------------------------------------- utf8

// JavaScript strings are UTF-16, so these count code points: a character
// outside the Basic Multilingual Plane (an emoji) is one character, not two.
// Indices are 0-based code-point indices.

/** Bytes the string takes as UTF-8 (a lone surrogate counts 3). */
export function utf8ByteLength(s: string): number {
  let n = 0;
  for (const ch of s) {
    const cp = ch.codePointAt(0)!;
    n += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
  }
  return n;
}

/** Number of characters, not UTF-16 units. */
export function utf8Len(s: string): number {
  let n = 0;
  for (const _ of s) n++;
  return n;
}

/** Iterate characters as [index, char], index in characters from 0. */
export function* utf8Chars(s: string): Generator<[number, string]> {
  let i = 0;
  for (const ch of s) yield [i++, ch];
}

/** Nearest character boundary at or before `i`. In characters every index is
 * one, so this only clamps to 0…length (Lua's version steps back off a
 * continuation byte). */
export function utf8Floor(s: string, i: number): number {
  if (i < 0) return 0;
  const len = utf8Len(s);
  if (i > len) return len;
  return Math.floor(i);
}

/** Codepoint of the character at index `i`, or undefined past the end. */
export function utf8Codepoint(s: string, i: number): number | undefined {
  for (const [k, ch] of utf8Chars(s)) if (k === i) return ch.codePointAt(0);
  return undefined;
}

// ------------------------------------------------------------------------ id

let idCounter = 0;

const hex = (n: number, width: number): string => n.toString(16).padStart(width, "0");

/** Short unique id for segments and takes.
 * Combines time, a process-lifetime counter and Math.random, which is enough
 * for keys that only need to be unique within one project. Same shape as the
 * Lua's ids. */
export function newId(): string {
  idCounter++;
  const time = Math.floor(Date.now() / 1000) % 0xFFFFFF;
  return hex(time, 1) + hex(idCounter % 0xFFF, 3) + hex(Math.floor(Math.random() * 0x1000), 3);
}

/** Seconds as m:ss — a counter, not a timeline position. */
export function formatClock(seconds: unknown): string {
  const f = Math.floor(toNumber(seconds) ?? 0);
  const s = f > 0 ? f : 0;                  // Lua's math.max(0, NaN) is 0
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

/** Seconds as m:ss.t — the form editors read on a timeline. */
export function formatDuration(seconds: unknown): string {
  const n = toNumber(seconds) ?? 0;
  const m = Math.floor(n / 60);
  const s = n - m * 60;
  // Lua's "%d:%04.1f"; toFixed rounds an exact tie away from zero, as the
  // macOS printf the Resolve build runs on does.
  return `${m}:${s.toFixed(1).padStart(4, "0")}`;
}
