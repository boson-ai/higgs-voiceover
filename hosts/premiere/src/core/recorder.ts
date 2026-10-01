// Recording a voice reference: the rules, kept away from the widgets.
// Port of hosts/resolve/src/higgs/recorder.lua.
//
// Capture itself is three platform calls (start, stop, is-running); what is
// worth testing is everything around them — when a take is long enough to
// send, when it is too quiet or too loud to be worth sending, and what to say
// about it. Those are pure functions here so they can be checked without a
// microphone.
//
// The thresholds come from Boson's own guidance (5–30 s of clean speech, hard
// minimum 3.0 s) plus what a peak meter can honestly tell from 16-bit PCM.

/** Boson rejects anything under this; there is no point asking. */
export const MIN_SECONDS = 3.0;
/** The range Boson recommends for a reference, and the length to aim for
 * inside it: long enough to carry pace and timbre, short enough to read in
 * one breath-group without the speaker drifting. */
export const GOOD_MIN = 5;
export const GOOD_MAX = 30;
export const IDEAL = 20;

/** Below this average level the signal is too near the noise floor to clone
 * well — a microphone at the wrong end of the room, or the wrong input
 * selected. -35 dBFS RMS, the floor voice-over guides give for a usable take. */
export const QUIET_RMS = 0.0178;
/** At or above this a 16-bit sample is at the ceiling; a few are normal on a
 * plosive, a lot means the gain is too high and the peaks are square. */
export const HOT_PEAK = 0.98;
/** Clipping matters once it stops being the occasional sample. */
export const HOT_RATIO = 0.005;

/** Words per second of natural narration. Outside this the take is being
 * rushed or laboured, and the clone learns that pace. We can only measure it
 * because Boson requires a verbatim transcript in the first place. */
export const SLOW_WPS = 1.8;
export const FAST_WPS = 4.0;

export interface TakeStats {
  seconds?: number;
  peak?: number;
  rms?: number;
  hot_ratio?: number;
}

export interface Verdict {
  ok: boolean;
  kind: "error" | "warn" | "ok";
  message: string;
  /** Nothing at all came in: the caller explains microphone permission. */
  silent?: true;
  /** The one warning the dialog still shows. */
  clipped?: true;
  good?: true;
}

// Lua's tonumber() for what can reach here: numbers and numeric strings.
function num(v: unknown): number | null {
  if (typeof v === "number") return v;
  if (typeof v === "string") {
    const s = v.trim();
    if (/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s)) return Number(s);
  }
  return null;
}

/** What the meter should read, 0–1, given a peak sample.
 * Peak amplitude is linear, and linear is useless to look at: normal speech
 * sits under 0.25 and would never leave the first quarter of the bar. This is
 * the usual fix — map decibels, not amplitude, over the range a voice uses. */
export function meter(peak: unknown): number {
  const p = num(peak) ?? 0;
  if (p <= 0) return 0;
  const db = 20 * Math.log(p) / Math.log(10);   // 0 dBFS at full scale
  const FLOOR = -54;
  if (db <= FLOOR) return 0;
  if (db >= 0) return 1;
  return (db - FLOOR) / -FLOOR;
}

/** Words in a transcript, for the pace check. Counts runs of non-space, which
 * is close enough for a ratio and works on scripts without spaces too badly. */
export function wordCount(text: unknown): number {
  const m = String(text ?? "").match(/[^ \t\n\v\f\r]+/g);
  return m ? m.length : 0;
}

/** Judge a finished take. `ok` means "we can send this"; a warning is still
 * sendable, because the user has just heard their own recording and is a
 * better judge of it than any of these numbers.
 *
 * Order matters: the blocking faults come first, then the one the user can
 * least afford to ignore. Only one line is ever shown, so it has to be the
 * most useful one. */
export function judge(take: TakeStats | null | undefined, transcript?: string | null): Verdict {
  const seconds = num(take?.seconds) ?? 0;
  const peak = num(take?.peak) ?? 0;
  const rms = num(take?.rms) ?? 0;
  const hot = num(take?.hot_ratio) ?? 0;

  if (seconds < MIN_SECONDS) {
    return { ok: false, kind: "error",
             message: `Only ${seconds.toFixed(1)} seconds — Boson needs at least ${MIN_SECONDS.toFixed(0)}. Around ${IDEAL} is about right.` };
  }
  if (peak <= 0.0005) {
    return { ok: false, kind: "error", silent: true,
             message: "Nothing reached the microphone." };
  }
  if (rms < QUIET_RMS) {
    return { ok: false, kind: "error",
             message: "Too quiet to clone from. Move closer to the microphone, or turn its input up, and record again." };
  }
  if (hot > HOT_RATIO) {
    // `clipped` marks the one warning the dialog still shows: distortion is
    // inaudible while recording and permanent once a voice is made from it.
    return { ok: true, kind: "warn", clipped: true,
             message: "Loud enough to distort in places. Turning the input down and recording again will give a cleaner voice." };
  }
  const words = wordCount(transcript);
  if (words > 0 && seconds > 0) {
    const wps = words / seconds;
    if (wps > FAST_WPS) {
      return { ok: true, kind: "warn",
               message: "That was read quickly, and the voice will copy the pace. Reading it the way you would say it gives a better clone." };
    }
    if (wps < SLOW_WPS) {
      return { ok: true, kind: "warn",
               message: "That was read slowly, and the voice will copy the pace. Reading it the way you would say it gives a better clone." };
    }
  }
  if (seconds < GOOD_MIN) {
    return { ok: true, kind: "warn",
             message: `${seconds.toFixed(1)} seconds will work, but around ${IDEAL} gives Boson more to go on.` };
  }
  // Nothing wrong with it, and saying so is worth a line: the user has no
  // meter any more and no other way to know the take is good.
  return { ok: true, kind: "ok", good: true,
           message: `Good — ${seconds.toFixed(0)} seconds at a clear level.` };
}

/** Passages to read. Written for prosody rather than phonetic coverage: at
 * twenty seconds a clone learns timbre and pace, and a flat read of a word
 * list teaches it to be flat. Each is first person, conversational, about
 * sixty words, and carries a question and an emphatic clause so the voice has
 * somewhere to move. Three of them because identical audio returns the same
 * voice id from Boson — a second voice needs different words. */
export const PASSAGES: readonly string[] = [
  "I have been cutting video for about ten years now, and the part I still like best is the hour before anyone else is awake. No messages, no notes, nothing but the timeline. Does that sound strange? Maybe it does. But that is when the work actually happens, and honestly, nothing else in my day comes close to it.",
  "Here is the thing nobody tells you about narration: the writing matters more than the voice. You can have the warmest voice in the world and still lose people in the second sentence. So do I read the script out loud first? Every single time. And wherever I stumble, that is the line I go back and rewrite.",
  "We shot the whole thing in one afternoon, which I would not recommend to anybody. The light kept changing, the battery died twice, and somebody's phone went off right in the middle of the best take we had. Would I do it again? Probably, yes. It is still the one people write to me about, years later.",
];

/** What the level is doing right now, as a word rather than a meter.
 * Returns null when there is nothing worth saying, which is most of the time. */
export function levelNote(peak: unknown): { message: string; kind: "warn" } | null {
  const p = num(peak) ?? 0;
  if (p >= HOT_PEAK) return { message: "Too loud — move back a little.", kind: "warn" };
  if (p > 0 && p < 0.02) return { message: "Very quiet — move closer to the microphone.", kind: "warn" };
  return null;
}

/** What to say to someone who is recording right now. One rule in one place:
 * the dialog asks at every tick and never decides for itself. */
export function coach(seconds: unknown, limit?: unknown): string {
  const s = num(seconds) ?? 0;
  const l = num(limit) ?? GOOD_MAX;
  if (s >= l - 5) return `Recording stops at ${Math.trunc(l)} seconds.`;
  if (s >= IDEAL - 2) return "That is enough — stop whenever you reach the end.";
  if (s < MIN_SECONDS) return `Keep going — ${MIN_SECONDS.toFixed(0)} seconds is the minimum, ${IDEAL} is ideal.`;
  return `Around ${IDEAL} seconds is ideal.`;
}
