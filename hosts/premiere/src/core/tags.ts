// Higgs TTS control-tag taxonomy and the rules for composing them.
// Port of hosts/resolve/src/higgs/tags.lua.
//
// Higgs TTS 3 has no SSML. Delivery is directed with inline `<|category:value|>`
// tokens inside the input text. This module is the single source of truth for
// which tags exist and where they are allowed to sit, so the UI can offer
// direction as menus while the API still receives plain tagged text.
//
// Placement rule from Boson's docs: emotion, style, speed, pitch and
// expressiveness apply from the start of a turn, so they lead the text. Pauses
// and sound effects are positional and stay where the user put them.
//
// Offsets: where the Lua counts UTF-8 bytes, this counts JS string indices
// (UTF-16 code units) — the unit of a textarea's selectionStart.

export interface TagOption {
  value: string;
  label: string;
}

export interface Direction {
  emotion?: string;
  style?: string;
  speed?: string;
  pitch?: string;
  expressiveness?: string;
}

/** 21 emotions, in the order Boson documents them. */
export const EMOTIONS: readonly string[] = [
  "elation", "amusement", "enthusiasm", "determination", "pride", "contentment",
  "affection", "relief", "contemplation", "confusion", "surprise", "awe",
  "longing", "arousal", "anger", "fear", "disgust", "bitterness", "sadness",
  "shame", "helplessness",
];

export const STYLES: readonly string[] = ["singing", "shouting", "whispering"];

/** Sound effects are voiced by the speaker, and Boson's guidance is to
 * follow each with the written sound: "<|sfx:laughter|>Haha". The words are
 * Boson's own examples, always in English whatever the line's language;
 * crying has none (Boson's example has none either). */
export const SFX: readonly string[] = [
  "cough", "laughter", "crying", "screaming", "burping", "humming",
  "sigh", "sniff", "sneeze",
];
export const SFX_WORDS: Readonly<Record<string, string>> = {
  cough: "Ahem", laughter: "Haha", screaming: "Ah", burping: "Burp",
  humming: "Hmm", sigh: "Ahh", sniff: "Sff...", sneeze: "Achoo",
};

/** Prosody splits into four independent axes. Each is a leading tag except
 * pauses, which are positional. */
export const SPEEDS: readonly TagOption[] = [
  { value: "", label: "Normal" },
  { value: "speed_very_slow", label: "Very slow (~0.65×)" },
  { value: "speed_slow", label: "Slow (~0.85×)" },
  { value: "speed_fast", label: "Fast (~1.2×)" },
  { value: "speed_very_fast", label: "Very fast (~1.4×)" },
];

export const PITCHES: readonly TagOption[] = [
  { value: "", label: "Normal" },
  { value: "pitch_low", label: "Low (~−3 st)" },
  { value: "pitch_high", label: "High (~+2.5 st)" },
];

export const EXPRESSIVENESS: readonly TagOption[] = [
  { value: "", label: "Normal" },
  { value: "expressive_low", label: "Restrained" },
  { value: "expressive_high", label: "Expressive" },
];

export const PAUSES: readonly TagOption[] = [
  { value: "prosody:pause", label: "Pause (~0.4–0.7 s)" },
  { value: "prosody:long_pause", label: "Long pause (~0.7–1.5 s)" },
];

/** The service's per-request ceiling: a line already at the limit is left
 * alone by terminate() rather than pushed over it. */
export const MAX_CHARS = 5000;

// Lua's %s: ASCII whitespace only, never the Unicode spaces JS \s also takes.
const SPACE = "[ \\t\\n\\v\\f\\r]";
const LEADING_SPACE = new RegExp(`^${SPACE}+`);
const TRAILING_SPACE = new RegExp(`${SPACE}+$`);

function trim(s: string): string {
  return s.replace(LEADING_SPACE, "").replace(TRAILING_SPACE, "");
}

function asciiLower(s: string): string {
  return s.replace(/[A-Z]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 32));
}

function utf8Length(s: string): number {
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x80) n += 1;
    else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const lo = s.charCodeAt(i + 1);
      if (lo >= 0xdc00 && lo <= 0xdfff) { n += 4; i++; } else n += 3;
    } else n += 3;
  }
  return n;
}

function codepointCount(s: string): number {
  let n = 0;
  for (const _ of s) n++;
  return n;
}

/** What a tag sets for the whole line, so a new one replaces the old:
 * emotion, style, speed, pitch or expressiveness. Pauses and sound effects
 * are positional and return null. */
export function kind(value: unknown): string | null {
  const v = String(value ?? "");
  if (v.startsWith("emotion:")) return "emotion";
  if (v.startsWith("style:")) return "style";
  const axis = /^prosody:([A-Za-z]+)_/.exec(v)?.[1];
  if (axis === "speed" || axis === "pitch" || axis === "expressive") return axis;
  return null;
}

/** Categories offered by the "insert tag" control, in menu order. */
export function categories(): string[] {
  return ["Emotion", "Style", "Prosody", "Sound effect"];
}

export function valuesFor(category: string): TagOption[] {
  if (category === "Emotion") return EMOTIONS.map((e) => ({ value: "emotion:" + e, label: e }));
  if (category === "Style") return STYLES.map((s) => ({ value: "style:" + s, label: s }));
  if (category === "Sound effect") return SFX.map((s) => ({ value: "sfx:" + s, label: s }));
  if (category === "Prosody") {
    const out: TagOption[] = PAUSES.map((p) => ({ ...p }));
    for (const t of [SPEEDS, PITCHES, EXPRESSIVENESS]) {
      for (const item of t) {
        if (item.value !== "") out.push({ value: "prosody:" + item.value, label: item.label });
      }
    }
    return out;
  }
  return [];
}

/** Close an unpunctuated line so the model reads it as a finished
 * sentence. Without a terminator it runs the last word to the edge of the
 * clip and skips the falling intonation and the small tail that make a
 * pause afterwards sound natural. A line already ending in punctuation, or
 * in a tag, is left exactly as it is. */
export function terminate(text: unknown, maxChars = MAX_CHARS): string {
  const s = String(text ?? "");
  if (s === "" || s.endsWith("|>")) return s;
  if (codepointCount(s) >= maxChars) return s;
  const cp = s.codePointAt(s.length - 1);
  // A trailing surrogate pair: its codepoint starts one unit earlier.
  const last = cp !== undefined && cp >= 0xdc00 && cp <= 0xdfff && s.length > 1
    ? s.codePointAt(s.length - 2)!
    : cp;
  if (last === undefined) return s;

  if (last < 0x80) {
    // Plain ASCII: only an unfinished word needs closing.
    return /[A-Za-z0-9]/.test(String.fromCharCode(last)) ? s + "." : s;
  }
  // Punctuation that already ends a sentence, western or CJK.
  if ((last >= 0x2000 && last <= 0x206f)          // – — … ‘ ’ “ ”
      || (last >= 0x3001 && last <= 0x303f)       // 、。〈〉《》
      || (last >= 0xff01 && last <= 0xff65)) {    // fullwidth ！？．
    return s;
  }
  // CJK and kana take a fullwidth stop; every other script a plain one.
  if ((last >= 0x3040 && last <= 0x9fff) || (last >= 0xac00 && last <= 0xd7af)
      || (last >= 0xf900 && last <= 0xfaff)) {
    return s + "。";
  }
  return s + ".";
}

/** Render one tag token. */
export function token(value: unknown): string {
  return "<|" + String(value) + "|>";
}

const LEADING_TAG = new RegExp(`${SPACE}*<\\|([^|>]*?)\\|>`, "y");

/** Work out the text after inserting `value` at a point, given everything
 * before and after it. `lineStart` tags (speed, pitch, expressiveness)
 * only take effect at the start of a turn, so they move to the front of
 * that line and replace any tag already there on the same axis.
 * Also returns where the caret belongs afterwards, as a UTF-16 index into
 * the result (the Lua returns a byte offset): right after an inserted
 * positional tag; for a line-start tag, where it was in the user's text
 * (never inside the new tag). */
export function placeTag(before: string, after: string, value: string, lineStart: boolean): { text: string; caret: number } {
  const tok = token(value);
  if (!lineStart) {
    const sfx = /^sfx:([\s\S]+)$/.exec(value)?.[1];
    if (sfx !== undefined) {
      // The tag sits right on its sound, as in Boson's examples; a sound
      // already typed after the caret is not added twice.
      const word = Object.prototype.hasOwnProperty.call(SFX_WORDS, sfx) ? SFX_WORDS[sfx] : undefined;
      if (!word) return { text: before + tok + after, caret: before.length + tok.length };
      const rest = after.replace(LEADING_SPACE, "");
      if (asciiLower(rest.slice(0, word.length)) === asciiLower(word)) {
        return { text: before + tok + rest, caret: before.length + tok.length + word.length };
      }
      return { text: before + tok + word + " " + after, caret: before.length + tok.length + word.length + 1 };
    }
    return { text: before + tok + " " + after, caret: before.length + tok.length + 1 };
  }
  const nl = before.lastIndexOf("\n");
  const head = nl >= 0 ? before.slice(0, nl + 1) : "";
  const line = nl >= 0 ? before.slice(nl + 1) : before;
  // The tags leading the line set it up; one of the same kind is replaced.
  const k = kind(value);
  const rest = line + after;
  const kept: string[] = [];
  let pos = 0;
  for (;;) {
    LEADING_TAG.lastIndex = pos;
    const m = LEADING_TAG.exec(rest);
    if (!m) break;
    if (kind(m[1]) !== k) kept.push(token(m[1]));
    pos = LEADING_TAG.lastIndex;
  }
  const text = rest.slice(pos).replace(LEADING_SPACE, "");
  const out = head + tok + " " + (kept.length > 0 ? kept.join(" ") + " " : "") + text;
  return { text: out, caret: Math.max(out.length - after.length, head.length + tok.length + 1) };
}

/** Compose the text sent to the API from a segment's text plus its direction.
 *
 * The user's text may already contain positional tags (pauses, effects) that
 * they inserted by hand; those are left exactly where they are. Direction chosen
 * in the inspector is prepended, because those tags only take effect at the
 * start of a turn. Any direction field may be missing or "" to mean "leave it
 * alone". */
export function compose(text: string | null | undefined, direction?: Direction | null): string {
  const d = direction ?? {};
  const lead: string[] = [];
  if (d.emotion) lead.push(token("emotion:" + d.emotion));
  if (d.style) lead.push(token("style:" + d.style));
  for (const key of ["speed", "pitch", "expressiveness"] as const) {
    const v = d[key];
    if (v) lead.push(token("prosody:" + v));
  }
  const body = trim(String(text ?? ""));
  if (lead.length === 0) return body;
  return lead.join(" ") + " " + body;
}

/** Billable characters for a composed segment.
 * Boson bills the full input including tags, so estimates must count the
 * composed string rather than the visible words. Counted in UTF-8 bytes, as
 * the Lua's `#` does. */
export function billableLength(text: string | null | undefined, direction?: Direction | null): number {
  return utf8Length(compose(text, direction));
}

/** Does this text already carry a leading direction tag?
 * Used to warn when hand-written tags and inspector settings would both apply. */
export function hasLeadingTag(text: string | null | undefined): boolean {
  const first = /^<\|[^|]+\|>/.exec(trim(String(text ?? "")))?.[0];
  if (!first) return false;
  const k = /^<\|([A-Za-z]+):/.exec(first)?.[1];
  return k === "emotion" || k === "style" || k === "prosody";
}
