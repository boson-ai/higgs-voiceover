// Subtitles from a take: split the line into subtitles and time them to the
// words Boson says it spoke.
//
// Ported from the Resolve build's subtitles.lua. Pure: no Premiere and no
// UXP — the whole path from a line of text and a list of word timings to an
// .srt file is here, so it can be tested in Node.
//
// The rules follow common subtitling practice (Netflix's Timed Text Style
// Guide, which Resolve's own auto-captions also use as their preset):
//
//   * one line of at most 42 characters in Latin, Cyrillic, Arabic and other
//     alphabets, 16 in Chinese and Korean, 13 in Japanese, 35 in Thai —
//     measured per character, so a line mixing scripts gets a fair share;
//   * never two sentences in one subtitle, whatever the script's full stop
//     (. 。 ！ ？ । ۔ ؟ …);
//   * break after punctuation, before a conjunction or preposition, and never
//     between an article and its noun, a preposition and its object, a
//     subject pronoun and its verb, an auxiliary and its verb;
//   * a subtitle stays up at least 20 frames at 24 fps (0.83 s);
//   * the last subtitle before a silence stays up about half a second after
//     the voice stops;
//   * a gap between two subtitles shorter than 0.8 s is filled by extending
//     the first to where the second starts, so the text does not blink off
//     and on between phrases (Alex, 2026-09-23 — in place of the 2-frame gap
//     broadcast guides use).
//
// Two ways to split, chosen in Settings:
//   "short"    — short phrases that fit one line, broken at the most natural
//                points (the default);
//   "sentence" — one subtitle per sentence, on up to two lines; a sentence
//                longer than two lines continues in the next subtitle.
//
// Token indices (a cue's `first`/`last`, a token's `word`) are 0-based here,
// 1-based in the Lua. Where the Lua measures a key in UTF-8 bytes — the
// look-ahead when matching words, a token's weight when spreading time — this
// port measures bytes too, so both hosts time a line alike.

import { isIdeographic, isPunct, stripTags, toNumber, trim, utf8ByteLength } from "./text.ts";

export const MODES = ["short", "sentence"] as const;
export type Mode = (typeof MODES)[number];
export const LIMIT = 42;          // width of a line, in Latin characters
export const LIMIT_CJK = 16;      // Chinese and Korean characters per line
export const LIMIT_JA = 13;       // Japanese (kana) characters per line
export const LIMIT_TH = 35;       // Thai characters per line
export const MIN_SECONDS = 20 / 24;
export const MAX_SECONDS = 7;
export const FILL_SECONDS = 0.8;  // a gap shorter than this is filled by the subtitle before it
export const LAG_SECONDS = 0.5;   // how long a subtitle stays after the voice stops

/** A piece of display text: a word in spaced scripts, one character in
 * Chinese and Japanese. `s`/`e` (seconds) and `word` (index into Boson's
 * list) are set by `align`. */
export interface Token {
  text: string;
  key: string;
  space: boolean;
  cjk: boolean;
  width: number;
  s?: number;
  e?: number;
  word?: number;
}

/** One entry of Boson's word timings. */
export interface Word {
  word?: unknown;
  start?: unknown;
  end?: unknown;
}

/** A subtitle, in seconds; `frames` adds `from`/`to` (and `limit`, the
 * frame of `bound`). */
export interface Cue {
  text: string;
  lines?: string[];
  first?: number;
  last?: number;
  start: number;
  finish: number;
  bound?: number;
  from?: number;
  to?: number;
  limit?: number;
}

export type FramedCue = Cue & { from: number; to: number };

export interface Take {
  text?: unknown;
  words?: Word[] | null;
  seconds?: unknown;
  pause?: unknown;
}

export type Method = "words" | "estimate";
export type Ending = "sentence" | "clause" | undefined;

// -------------------------------------------------------------------- tokens

const words = (list: string): string[] => list.split(/\s+/).filter((w) => w !== "");

/** Words a subtitle should not end on: they belong with what follows. */
const BIND_NEXT = new Set(words(`a an the this that these those my your his her its our their
  some any no every each either neither another such
  to of in on at for with from by about into onto over under after before
  between through during without within upon than as
  and but or nor so yet because although though if when while whereas unless
  until since whether
  i he she we they
  am is are was were be been being
  will would shall should can could may might must do does did have has had
  not don't doesn't didn't won't can't couldn't wouldn't shouldn't isn't aren't
  wasn't weren't haven't hasn't hadn't
  i'm you're we're they're he's she's it's i've you've we've they've i'll
  you'll we'll they'll i'd you'd we'd they'd
  mr mrs ms dr very more most just
  el la los las un una unos unas mi tu su nuestro nuestra sus mis tus
  de del al en con para por sin sobre entre hacia desde hasta
  y e o u pero que porque cuando como si aunque
  no se me te le lo nos les es son era fue
  puede podría debe quiere va voy vamos ha han he hemos había está están estaba`));

/** Words a subtitle may begin with comfortably: a break just before a
 * conjunction is the most natural after punctuation; before a preposition
 * or a determiner, a little less so ("nobody | on the team" splits a noun
 * phrase). */
const BREAK_BEFORE = new Map<string, number>();
for (const w of words(`and but or nor so yet because although though if when while whereas
  unless until since whether which who whom whose where that
  y o pero porque cuando aunque mientras donde que quien`)) BREAK_BEFORE.set(w, 3);
for (const w of words(`to of in on at for with from by about into over after before between
  through during without than
  de en con para por sin sobre desde hasta`)) BREAK_BEFORE.set(w, 6);
// A noun phrase starts with its determiner: "believed | a small studio" is a
// better cut than anywhere inside the phrase.
for (const w of words(`a an the this these those my your his her its our their some every each
  el la los las un una unos unas`)) if (!BREAK_BEFORE.has(w)) BREAK_BEFORE.set(w, 7);

/** Abbreviations whose full stop does not end a sentence. */
const ABBREV = new Set(words("mr mrs ms dr jr sr prof vs eg ie sra srta"));

const OPENING = new Set([   // marks that belong to the word after them
  0x22, 0x28, 0x5B, 0x7B, 0xBF, 0xA1,
  0xAB, 0x201E, 0x201A,
  0x201C, 0x2018, 0x300C, 0x300E, 0x300A,
  0x3008, 0xFF08, 0x3010,
]);
const SENTENCE_END = new Set([
  0x2E, 0x21, 0x3F,
  0x3002, 0xFF01, 0xFF1F, 0xFF0E, 0xFF61,   // CJK
  0x061F, 0x06D4,                           // Arabic, Urdu
  0x0964, 0x0965,                           // Devanagari danda
  0x0589, 0x1362,                           // Armenian, Ethiopic
  0x203C, 0x2047, 0x2048, 0x2049,
]);
const CLAUSE_END = new Set([
  0x2C, 0x3B, 0x3A, 0x2014, 0x2013, 0x2026,
  0x3001, 0xFF0C, 0xFF1B, 0xFF1A, 0x2D,
  0xFF64, 0x060C, 0x061B,
]);
const CLOSING = new Set([   // quotes and brackets that may follow a sentence's full stop
  0x22, 0x27, 0x29, 0x5D, 0x7D,
  0x201D, 0x2019, 0x300D, 0x300F, 0x300B,
  0x3009, 0xFF09, 0x3011, 0xBB,
]);

/** Punctuation in any script. text.ts's list covers ASCII and the CJK and
 * general punctuation blocks; these are the rest a subtitle meets. */
function isMark(cp: number): boolean {
  return isPunct(cp) || SENTENCE_END.has(cp) || CLAUSE_END.has(cp) || OPENING.has(cp)
      || CLOSING.has(cp) || cp === 0xB7;
}

/** Lua's `%s`: ASCII whitespace only. */
const isSpace = (cp: number): boolean => cp === 32 || (cp >= 9 && cp <= 13);

/** How much of a line one character takes, in Latin characters. A line is
 * 42 of them; each script's own per-line limit fits the same 42. */
export function charWidth(cp: number): number {
  if ((cp >= 0x3040 && cp <= 0x30FF) || (cp >= 0xFF66 && cp <= 0xFF9D)) {
    return LIMIT / LIMIT_JA;                                      // kana
  } else if ((cp >= 0x3400 && cp <= 0x4DBF) || (cp >= 0x4E00 && cp <= 0x9FFF)
      || (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0x3000 && cp <= 0x303F)
      || (cp >= 0xFF00 && cp <= 0xFF65)
      || (cp >= 0xAC00 && cp <= 0xD7AF) || (cp >= 0x1100 && cp <= 0x11FF)
      || (cp >= 0x3130 && cp <= 0x318F)) {
    return LIMIT / LIMIT_CJK;                                     // Han, Hangul, full-width
  } else if (cp >= 0x0E00 && cp <= 0x0E7F) {
    return LIMIT / LIMIT_TH;                                      // Thai
  }
  return 1;
}

export function textWidth(text: string): number {
  let w = 0;
  for (const ch of text) w = w + charWidth(ch.codePointAt(0)!);
  return w;
}

/** What a subtitle shows for a line: the tags removed, spaces collapsed. */
export function displayText(line: unknown): string {
  let s = stripTags(String(line ?? ""));
  s = s.replace(/[ \t\n\v\f\r]+/g, " ");
  return trim(s);
}

/** Lower-case letters and digits only: how a typed word and a word from
 * Boson's list are compared ("We're," and "we're" and "were" all match).
 * Only A–Z are lowered, as Lua's string.lower does in the C locale. */
export function keyOf(text: string): string {
  let out = "";
  for (const ch of text) {
    const cp = ch.codePointAt(0)!;
    if (cp === 39 || cp === 0x2019) {
      // an apostrophe, straight or curly, is dropped rather than kept
    } else if (!isMark(cp) && !(cp < 128 && isSpace(cp))) {
      out += cp >= 65 && cp <= 90 ? String.fromCharCode(cp + 32) : ch;
    }
  }
  return out;
}

/** Split display text into tokens: words in spaced scripts, single
 * characters in Chinese and Japanese. Punctuation rides on the token next
 * to it; `space` records whether a space came before the token. */
export function tokenize(text: string): Token[] {
  const tokens: Token[] = [];
  let cur: Token | undefined;
  let spacePending = false;
  let prefix = "";

  const flush = (): void => {
    if (cur) {
      cur.key = keyOf(cur.text);
      tokens.push(cur);
      cur = undefined;
    }
  };
  const start = (ch: string, cjk: boolean): void => {
    cur = { text: prefix + ch, key: "", space: spacePending && tokens.length > 0, cjk, width: 0 };
    prefix = "";
    spacePending = false;
  };

  for (const ch of text) {
    const cp = ch.codePointAt(0)!;
    if (isSpace(cp)) {
      flush();
      spacePending = true;
    } else if (isIdeographic(cp)) {
      flush();
      start(ch, true);
    } else if (isMark(cp) && cp !== 39) {
      // An opening mark belongs to the word after it: at the start of a
      // word, or after a Chinese/Japanese character ("说「好」").
      const opens = OPENING.has(cp) && (cur === undefined || (cur.cjk && cp !== 0x22));
      if (opens) {
        flush();
        prefix = prefix + ch;
      } else if (cur) {
        cur.text = cur.text + ch;
      } else if (tokens.length > 0 && prefix === "") {
        // A mark standing alone (" — ") rides on the word before it.
        const last = tokens[tokens.length - 1];
        last.text = last.text + (spacePending ? " " : "") + ch;
        spacePending = false;
      } else {
        prefix = prefix + ch;
      }
    } else {
      if (cur && cur.cjk) flush();
      if (cur) cur.text = cur.text + ch;
      else start(ch, false);
    }
  }
  flush();
  if (prefix !== "") {
    if (tokens.length > 0) tokens[tokens.length - 1].text += prefix;
    else tokens.push({ text: prefix, key: "", space: false, cjk: false, width: 0 });
  }
  for (const t of tokens) t.width = textWidth(t.text);
  return tokens;
}

/** The last codepoint of a token that is not a closing quote or bracket,
 * and the one before it. */
function finalMark(text: string): [number | undefined, number | undefined] {
  const cps = Array.from(text, (ch) => ch.codePointAt(0)!);
  let k = cps.length - 1;
  while (k > 0 && CLOSING.has(cps[k])) k--;
  return [cps[k], cps[k - 1]];
}

/** How a token ends: "sentence", "clause" or undefined. */
function tokenEnding(t: { text: string; key: string }): Ending {
  const [last, before] = finalMark(t.text);
  if (last === undefined) return undefined;
  if (SENTENCE_END.has(last)) {
    if (last === 0x2E && before === 0x2E) return "clause";   // "..." trails off
    if (last === 0x2E && ABBREV.has(t.key)) return undefined;
    return "sentence";
  }
  if (CLAUSE_END.has(last)) return "clause";
  return undefined;
}

export function ending(text: string): Ending {
  return tokenEnding({ text, key: keyOf(text) });
}

// -------------------------------------------------------------------- timing

/** Give every token a start and end in seconds.
 *
 * `words` is Boson's list ({ word, start, end }, in order) or null. Words are
 * matched to tokens by their letters, so punctuation, capitals and tags in
 * the typed text do not matter. A word Boson reports that is not in the text
 * (or one it spells differently) is skipped; a token no word landed on is
 * placed between its neighbours. With no list, or when too little of it
 * matches, timing is spread over the speech in proportion to length, with
 * extra room at punctuation — close enough for a subtitle to follow.
 *
 * Returns "words" or "estimate", for the log. */
export function align(tokens: Token[], words: Word[] | null | undefined, speechSeconds?: unknown): Method {
  const n = tokens.length;
  if (n === 0) return "estimate";
  const speech = Math.max(toNumber(speechSeconds) ?? 0, 0.1);

  // The text as one run of letters, which token owns each unit of it, and
  // where each unit sits in UTF-8 bytes (the look-ahead is 48 bytes, as in
  // the Lua).
  let stream = "";
  const owner: number[] = [];
  const starts = new Set<number>();
  tokens.forEach((t, ti) => {
    starts.add(stream.length);
    for (let u = 0; u < t.key.length; u++) owner[stream.length + u] = ti;
    stream += t.key;
  });
  const byteAt: number[] = [0];
  for (let u = 0; u < stream.length; u++) {
    const c = stream.charCodeAt(u);
    const size = c < 0x80 ? 1 : c < 0x800 ? 2 : (c >= 0xD800 && c <= 0xDBFF) ? 4 : (c >= 0xDC00 && c <= 0xDFFF) ? 0 : 3;
    byteAt[u + 1] = byteAt[u] + size;
  }

  if (Array.isArray(words) && words.length > 0) {
    let pos = 0;
    words.forEach((w, wi) => {
      const k = keyOf(String(w?.word ?? ""));
      const ws = toNumber(w?.start), we = toNumber(w?.end);
      if (k !== "" && ws !== undefined && we !== undefined) {
        let at: number | undefined;
        if (stream.startsWith(k, pos)) {
          at = pos;
        } else {
          // Look a little ahead for a word that starts a token; further than
          // that and the two lists have parted ways at this word.
          let from = pos;
          for (;;) {
            const f = stream.indexOf(k, from);
            if (f < 0 || byteAt[f] > byteAt[pos] + 48) break;
            if (starts.has(f)) { at = f; break; }
            from = f + 1;
          }
        }
        if (at !== undefined) {
          for (let u = at; u < at + k.length; u++) {
            const t = tokens[owner[u]];
            t.s = t.s !== undefined ? Math.min(t.s, ws) : ws;
            t.e = t.e !== undefined ? Math.max(t.e, we) : we;
            if (t.word === undefined) t.word = wi;
          }
          pos = at + k.length;
        }
      }
    });
  }

  let anchored = 0;
  for (const t of tokens) if (t.s !== undefined) anchored++;
  let keyed = 0;
  for (const t of tokens) if (t.key !== "") keyed++;

  // Weight for spreading time: the letters, plus a breath at punctuation.
  // Letters are counted in UTF-8 bytes, as the Lua's #key does.
  const weight = (t: Token): number => {
    const e = tokenEnding(t);
    return Math.max(utf8ByteLength(t.key), 1) + (e === "sentence" ? 6 : e === "clause" ? 3 : 1);
  };
  const spread = (from: number, to: number, a: number, b: number): void => {
    let total = 0;
    for (let i = from; i <= to; i++) total = total + weight(tokens[i]);
    let t0 = a;
    for (let i = from; i <= to; i++) {
      const share = (b - a) * weight(tokens[i]) / total;
      tokens[i].s = t0;
      tokens[i].e = t0 + share;
      t0 = t0 + share;
    }
  };

  if (anchored === 0 || anchored < keyed * 0.5) {
    for (const t of tokens) { delete t.s; delete t.e; delete t.word; }
    spread(0, n - 1, Math.min(0.05, speech / 10), speech);
    return "estimate";
  }

  // Fill the tokens no word landed on from the anchors around them.
  let i = 0;
  while (i < n) {
    if (tokens[i].s !== undefined) {
      i++;
    } else {
      let j = i;
      while (j + 1 < n && tokens[j + 1].s === undefined) j++;
      const prev = tokens[i - 1] as Token | undefined, next = tokens[j + 1] as Token | undefined;
      let est = 0;
      for (let k = i; k <= j; k++) est = est + weight(tokens[k]) * 0.06;
      const a = prev ? prev.e! : Math.max(0, (next ? next.s! : 0) - est);
      let b = next ? next.s! : Math.min(speech, a + est);
      if (b <= a) b = a + 0.01 * (j - i + 1);
      spread(i, j, a, b);
      i = j + 1;
    }
  }
  return "words";
}

// ----------------------------------------------------------------- splitting

/** Cost of ending a subtitle (or a line) after token i. Low is natural. */
function breakCost(tokens: Token[], i: number): number {
  const t = tokens[i], nx = tokens[i + 1] as Token | undefined;
  if (!nx) return 0;
  const e = tokenEnding(t);
  if (e === "sentence") return 0;
  let cost: number;
  if (e === "clause") cost = 1;
  else if (t.cjk && nx.cjk && t.word !== undefined && t.word === nx.word) cost = 60;   // inside one word
  else if (BIND_NEXT.has(t.key)) cost = 40;
  else cost = BREAK_BEFORE.get(nx.key) ?? 12;
  // A pause in the voice is a natural place to break, whatever the words.
  if (t.e !== undefined && nx.s !== undefined && nx.s - t.e >= 0.25) cost = Math.min(cost, 2);
  return cost;
}

/** Width of tokens i..j as shown, spaces included. */
function width(tokens: Token[], i: number, j: number): number {
  let w = 0;
  for (let k = i; k <= j; k++) {
    w = w + tokens[k].width + ((k > i && tokens[k].space) ? 1 : 0);
  }
  return w;
}

function join(tokens: Token[], i: number, j: number): string {
  let out = "";
  for (let k = i; k <= j; k++) out += ((k > i && tokens[k].space) ? " " : "") + tokens[k].text;
  return out;
}

const sq = (x: number): number => x * x;

/** Choose the breaks in tokens[from..to] so every piece fits `limit`,
 * minimising the cost of the breaks plus how ragged and fragmentary the
 * pieces are. `pieceCost(i, j, w)` adds a cost per piece. */
function bestBreaks(tokens: Token[], from: number, to: number, limit: number,
                    pieceCost: (i: number, j: number, w: number) => number): Array<[number, number]> {
  // best[k - from + 1] is the cheapest way to end a piece at token k.
  const best: number[] = [0];
  const back: number[] = [];
  for (let j = from; j <= to; j++) {
    let bj = Infinity;
    let bi = j;
    for (let i = j; i >= from; i--) {
      const w = width(tokens, i, j);
      if (w > limit && i < j) break;
      const c = best[i - from] + pieceCost(i, j, w) + (i > from ? breakCost(tokens, i - 1) : 0);
      if (c < bj) { bj = c; bi = i; }
    }
    best[j - from + 1] = bj;
    back[j - from] = bi;
  }
  const pieces: Array<[number, number]> = [];
  let j = to;
  while (j >= from) {
    const i = back[j - from];
    pieces.unshift([i, j]);
    j = i - 1;
  }
  return pieces;
}

/** Split aligned tokens into subtitles:
 * [{ text: "…", lines: ["…"], first: i, last: j, start: s, finish: e }]. */
export function split(tokens: Token[], mode?: string | null): Cue[] {
  const n = tokens.length;
  if (n === 0) return [];
  // Widths are in Latin characters, so one limit serves every script (a
  // Chinese character is 42/16 of one); the small margin absorbs rounding.
  const limit = LIMIT + 1e-6;
  const cues: Cue[] = [];

  const add = (i: number, j: number, lines: string[]): void => {
    cues.push({
      first: i, last: j, lines, text: lines.join("\n"),
      start: tokens[i].s ?? 0, finish: tokens[j].e ?? tokens[i].s ?? 0,
    });
  };

  // A phrase of one line, broken at the most natural points.
  const phraseCost = (i: number, j: number, w: number): number => {
    let c = 2 + sq((limit - Math.min(w, limit)) / limit) * 6;
    // A scrap of a sentence on its own is hard to read.
    if (w < limit * 0.35 && j < n - 1 && tokenEnding(tokens[j]) !== "sentence") c = c + 6;
    for (let k = i; k < j; k++) {
      const e = tokenEnding(tokens[k]);
      // A sentence always ends its subtitle, however short both are.
      if (e === "sentence") return Infinity;
      // One or two words of the next clause left hanging at the end
      // ("…this project, nobody"), or of the last one at the start.
      if (e) {
        if (j - k <= 2 && j < n - 1 && !tokenEnding(tokens[j])) c = c + 8;
        if (k - i + 1 <= 2 && i > 0 && !tokenEnding(tokens[i - 1])) c = c + 8;
      }
    }
    const s = tokens[i].s, e = tokens[j].e;
    if (s !== undefined && e !== undefined && e - s > MAX_SECONDS) c = c + (e - s - MAX_SECONDS) * 3;
    return c;
  };

  if (mode === "sentence") {
    // One subtitle per sentence, on up to two lines, as even as possible
    // with the longer line underneath unless punctuation decides. A
    // sentence too long for two lines is cut into natural phrases first
    // (the short-phrase rules), then the phrases are paired into two-line
    // subtitles — so every cut is one those rules chose, never "nobody | on".
    let i = 0;
    for (let j = 0; j < n; j++) {
      if (j === n - 1 || tokenEnding(tokens[j]) === "sentence") {
        const total = width(tokens, i, j);
        if (total <= limit) {
          add(i, j, [join(tokens, i, j)]);
        } else if (total <= limit * 2) {
          const target = total / 2;
          const lines = bestBreaks(tokens, i, j, limit, (_x, y, w) =>
            10 + sq((w - target) / limit) * 6 + ((y < j && w > target) ? 0.5 : 0),
          ).map(([a, b]) => join(tokens, a, b));
          add(i, j, lines);
        } else {
          const phrases = bestBreaks(tokens, i, j, limit, phraseCost);
          // Pair phrases: fewest subtitles, then the most natural cuts
          // between them. best/back count phrases from 1, as in the Lua.
          const m = phrases.length;
          const best: number[] = [0];
          const back: number[] = [];
          for (let k = 1; k <= m; k++) {
            best[k] = Infinity;
            for (let size = 1; size <= Math.min(2, k); size++) {
              const a = k - size + 1;
              const cut = a > 1 ? breakCost(tokens, phrases[a - 2][1]) : 0;
              const c = best[a - 1] + 10 + cut;
              if (c < best[k]) { best[k] = c; back[k] = a; }
            }
          }
          const groups: Array<[number, number]> = [];
          let k = m;
          while (k >= 1) {
            groups.unshift([back[k], k]);
            k = back[k] - 1;
          }
          for (const [g1, g2] of groups) {
            const lines: string[] = [];
            for (let q = g1; q <= g2; q++) lines.push(join(tokens, phrases[q - 1][0], phrases[q - 1][1]));
            add(phrases[g1 - 1][0], phrases[g2 - 1][1], lines);
          }
        }
        i = j + 1;
      }
    }
    return cues;
  }

  // Short phrases: one line each.
  for (const [a, b] of bestBreaks(tokens, 0, n - 1, limit, phraseCost)) add(a, b, [join(tokens, a, b)]);
  return cues;
}

/** A take's subtitles, in seconds from the start of the take.
 * `take` = { text: the line as typed (tags and all), words: Boson's list
 * or null, seconds: the clip's length, pause: trailing silence added }.
 * Subtitles are only made from Boson's word timings: without them (Boson
 * returned none, or too few matched the text) there are none, rather than
 * subtitles timed by guesswork (Alex, 2026-09-23). */
export function forTake(take: Take, mode?: string | null): [Cue[], "words" | "none"] {
  if (!Array.isArray(take.words) || take.words.length === 0) return [[], "none"];
  const tokens = tokenize(displayText(take.text));
  const speech = Math.max(0.1, (toNumber(take.seconds) ?? 0) - (toNumber(take.pause) ?? 0));
  const method = align(tokens, take.words, speech);
  if (method !== "words") return [[], "none"];
  return [split(tokens, mode), method];
}

/** A whole line as one subtitle, for a clip Boson gave no word timings
 * for: it runs the length of the clip — known exactly from where the clip
 * was placed — so nothing is guessed. Long lines wrap onto balanced lines. */
export function whole(text: unknown, seconds: unknown): Cue[] {
  const tokens = tokenize(displayText(text));
  if (tokens.length === 0) return [];
  const limit = LIMIT + 1e-6;
  const n = tokens.length;
  const total = width(tokens, 0, n - 1);
  const target = total / Math.max(1, Math.ceil(total / limit));
  const lines = bestBreaks(tokens, 0, n - 1, limit, (_x, y, w) =>
    10 + sq((w - target) / limit) * 6 + ((y < n - 1 && w > target) ? 0.5 : 0),
  ).map(([a, b]) => join(tokens, a, b));
  return [{ text: lines.join("\n"), lines, start: 0, finish: Math.max(0.1, toNumber(seconds) ?? 0) }];
}

// -------------------------------------------------------------------- frames

/** Snap subtitles to the timeline's frames and apply the timing rules.
 * `cues` are in seconds from a common origin, in order, each with an
 * optional `bound` (seconds) it must end by — the end of its clip. Returns
 * the same cues with `from` and `to` in frames (to is exclusive). */
export function frames(cues: Cue[], fps?: unknown): FramedCue[] {
  const rate = toNumber(fps) ?? 24;
  const minLen = Math.ceil(MIN_SECONDS * rate - 1e-6);
  const lag = Math.floor(LAG_SECONDS * rate + 0.5);
  const fill = Math.floor(FILL_SECONDS * rate + 0.5);
  const out = cues as FramedCue[];

  for (const c of out) {
    // In on the first frame of the voice, out on the frame after it stops.
    c.from = Math.floor(c.start * rate + 1e-6);
    c.to = Math.max(c.from + 1, Math.ceil(c.finish * rate - 1e-6));
    c.limit = c.bound !== undefined && c.bound !== null ? Math.floor(c.bound * rate + 1e-6) : undefined;
  }
  out.forEach((c, k) => {
    const nx = out[k + 1] as FramedCue | undefined, prev = out[k - 1] as FramedCue | undefined;
    // Words of neighbouring clips can sit closer than that; never overlap.
    if (prev && c.from < prev.to) {
      c.from = prev.to;
      c.to = Math.max(c.to, c.from + 1);
    }
    // Stay up a little after the voice, but not past the clip (the last
    // subtitle would drag the playhead beyond it) nor into the next one.
    let ceiling = c.limit !== undefined ? Math.max(c.limit, c.to) : Infinity;
    if (nx) ceiling = Math.min(ceiling, nx.from);
    let end = Math.min(c.to + lag, ceiling);
    if (end - c.from < minLen) end = Math.min(c.from + minLen, nx ? nx.from : Math.max(ceiling, c.from + minLen));
    c.to = Math.max(c.from + 1, end);
    // A gap shorter than FILL_SECONDS is filled: the subtitle stays up until
    // the next one starts, so the text does not blink off and on.
    if (nx && nx.from > c.to && nx.from - c.to < fill) c.to = nx.from;
    // Still too short to read: start a little earlier if there is room.
    if (c.to - c.from < minLen) {
      const floor = prev ? prev.to : 0;
      c.from = Math.max(floor, Math.min(c.from, c.to - minLen));
    }
  });
  return out;
}

// ----------------------------------------------------------------------- srt

/** C's %0Nd: zero-padded to `width`, the sign inside the width. */
function pad(n: number, width: number): string {
  const digits = String(Math.abs(n));
  return n < 0 ? "-" + digits.padStart(width - 1, "0") : digits.padStart(width, "0");
}

/** Lua's %: the result takes the divisor's sign. */
const mod = (a: number, b: number): number => a - Math.floor(a / b) * b;

function srtTime(frame: number, fps: number): string {
  const ms = Math.floor(frame * 1000 / fps + 0.5);
  const h = Math.floor(ms / 3600000);
  const m = mod(Math.floor(ms / 60000), 60);
  const s = mod(Math.floor(ms / 1000), 60);
  return `${pad(h, 2)}:${pad(m, 2)}:${pad(s, 2)},${pad(mod(ms, 1000), 3)}`;
}

/** SubRip text for framed cues. The first subtitle is written `lead`
 * frames in (default 0) and the rest keep their distance from it; returns
 * the text and the frame (in the cues' own frames) the first one starts on.
 * Resolve places an .srt by its first subtitle's time, so `lead` is how the
 * caller says where on the track it lands. */
export function srt(cues: Array<{ from: number; to: number; text: string }>, fps?: unknown, lead?: unknown): [string, number] {
  const rate = toNumber(fps) ?? 24;
  const origin = cues.length > 0 ? cues[0].from : 0;
  const shift = (toNumber(lead) ?? 0) - origin;
  const out: string[] = [];
  cues.forEach((c, i) => {
    out.push(String(i + 1));
    out.push(srtTime(c.from + shift, rate) + " --> " + srtTime(c.to + shift, rate));
    out.push(c.text);
    out.push("");
  });
  return [out.join("\n"), origin];
}

// ------------------------------------------------------------------- preview

/** How a line would be split, timing estimated from the text alone. Used by
 * the tests, and handy when tuning the rules. */
export function preview(text: unknown, mode?: string | null): string[] {
  const tokens = tokenize(displayText(text));
  align(tokens, null, Math.max(1, tokens.length * 0.33));
  return split(tokens, mode).map((c) => c.text);
}
