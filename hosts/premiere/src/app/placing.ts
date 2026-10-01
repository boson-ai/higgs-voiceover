// Putting a run's clips on the timeline, and their subtitles in the bin.
//
// Premiere's UXP API has no way yet to make a caption track or write a
// caption (Adobe: "working on it", 2025-09; still missing in 26.5 and the 27
// beta). So subtitles are written as an .srt timed from the first clip's
// start and imported into the bin; the user drags it onto the timeline at
// that clip. When Adobe adds captions, only the end of this file changes.

import type { Host, Take } from "../host/host.ts";
import type { Log } from "./log.ts";
import * as Subs from "../core/subtitles.ts";

export interface PlaceOutcome {
  ok: boolean;
  /** What to tell the user, and in which colour. */
  message: string;
  kind: "ok" | "error";
}

export interface PlaceOptions {
  trackName: string;
  subtitles: boolean;
  split: string;
  mode: "auto" | "all" | "one";
}

const stamp = () => {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
};

/**
 * The run's subtitles as one .srt, cue times measured from the first clip's
 * start as Premiere placed it. A take with word timings is split (Settings);
 * one without becomes its whole line over its clip. Returns the file and how
 * many takes went whole.
 */
export function subtitleFile(takes: Take[], starts: number[], ends: number[], fps: number, split: string): { text: string; cues: number; whole: number } {
  const origin = starts[0];
  const all: (Subs.Cue & { bound?: number })[] = [];
  let whole = 0;
  takes.forEach((take, i) => {
    if (!take.text) return;
    let [cues, method] = Subs.forTake(take as Subs.Take, split);
    if (method !== "words") {
      whole++;
      const length = ends[i] !== undefined ? ends[i] - starts[i] : take.seconds;
      cues = Subs.whole(take.text, length);
    }
    const offset = starts[i] - origin;
    for (const cue of cues) {
      // Bounded by the clip as placed: a clip's length is rounded to whole
      // frames, so the take's own length can overrun it by one.
      all.push({ ...cue, start: cue.start + offset, finish: cue.finish + offset, bound: (ends[i] ?? starts[i] + take.seconds) - origin });
    }
  });
  if (all.length === 0) return { text: "", cues: 0, whole };
  const framed = Subs.frames(all, fps);
  // srt() writes the first subtitle `lead` frames in: here, where its voice
  // starts after the first clip's start, so the file lines up when dropped there.
  const [text] = Subs.srt(framed, fps, framed[0].from);
  return { text, cues: framed.length, whole };
}

export async function placeTakes(host: Host, log: Log, takes: Take[], o: PlaceOptions): Promise<PlaceOutcome> {
  const metric = (ok: boolean, placed: number, error?: string) =>
    log.metric("place.quick", { mode: o.mode, clips: takes.length, placed, ok: ok ? 1 : 0, subtitles: o.subtitles ? 1 : 0, error });

  // No sequence: say what to do, and that nothing is lost — every take is
  // imported into the bin when it is generated.
  if (!(await host.timeline.hasSequence())) {
    metric(false, 0, "no sequence");
    return {
      ok: false, kind: "error",
      message: takes.length === 1 ? "Open a sequence to place this clip. It's already in your bin."
                                  : "Open a sequence to place these clips. They're already in your bin.",
    };
  }

  const res = await host.timeline.place(takes.map((t) => ({ path: t.path, seconds: t.seconds })), o.trackName);
  if (!res.ok) {
    metric(false, res.placed, res.error);
    const before = res.placed > 0 ? `Placed ${res.placed}, then failed: ` : "";
    return { ok: false, kind: "error", message: before + (res.error ?? "Could not place the clip.") };
  }
  metric(true, res.placed);
  const where = res.pushed ? "after the clip at the playhead" : "at the playhead";
  const what = res.placed === 1 ? `Placed on “${o.trackName}” ${where}`
                                : `Placed ${res.placed} clips on “${o.trackName}”, starting ${where}`;
  if (!o.subtitles) return { ok: true, kind: "ok", message: what + "." };

  const subs = subtitleFile(takes, res.starts, res.ends, res.fps, o.split);
  const done = (added: number, error?: string) =>
    log.metric("subtitles.place", { cues: subs.cues, added, ok: error ? 0 : 1, split: o.split, untimed: subs.whole, error, route: "bin" });
  if (subs.cues === 0) {
    done(0, "no text");
    return { ok: true, kind: "error", message: `${what}, but no subtitles: these lines have no text to show.` };
  }
  const first = takes[0].path;
  const path = first.replace(/\.[A-Za-z0-9]+$/, "") + `_subtitles_${stamp()}.srt`;
  if (!(await host.files.write(path, subs.text))) {
    done(0, "write");
    return { ok: true, kind: "error", message: `${what}, but no subtitles: couldn't write ${host.files.basename(path)}.` };
  }
  const imported = await host.timeline.importToBin([path]);
  if (!imported.ok) {
    done(0, imported.error);
    return { ok: true, kind: "error", message: `${what}, but no subtitles: ${String(imported.error ?? "Premiere would not import them").replace(/\.$/, "")}.` };
  }
  done(subs.cues);
  const whole = subs.whole > 0 ? ` ${subs.whole === 1 ? "1 line has" : subs.whole + " lines have"} no word timing and shows whole.` : "";
  return { ok: true, kind: "ok", message: `${what}. Subtitles are in the bin — drag them to the start of the ${res.placed === 1 ? "clip" : "first clip"}.${whole}` };
}
