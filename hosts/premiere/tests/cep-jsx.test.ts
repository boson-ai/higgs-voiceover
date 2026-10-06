// The CEP build's ExtendScript (cep/jsx/host.jsx), run in Node against a
// small stand-in of Premiere's scripting DOM: what it does with tracks,
// the bin, the playhead and captions. Premiere itself may differ — this
// pins down our side.

import { test } from "node:test";
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";

const SRC = readFileSync(new URL("../cep/jsx/host.jsx", import.meta.url), "utf8");

interface Clip { start: { seconds: number }; end: { seconds: number } }
function coll<T>(items: T[]) {
  const c: Record<string, unknown> = {};
  Object.defineProperty(c, "numItems", { get: () => items.length });
  Object.defineProperty(c, "numTracks", { get: () => items.length });
  return new Proxy(c, { get: (t, k) => (typeof k === "string" && /^\d+$/.test(k) ? items[Number(k)] : t[k as string]) });
}

function premiere(o: { playhead?: number; tracks?: { name: string; clips?: [number, number][]; locked?: boolean }[]; durations?: Record<string, number> } = {}) {
  const durations = o.durations ?? {};
  const rootChildren: unknown[] = [];
  const captions: { item: string; at: number; format: number }[] = [];
  const captionTracks: unknown[] = [];
  let nextId = 0;
  function track(name: string, spans: [number, number][] = [], locked = false) {
    const clips: Clip[] = spans.map(([s, e]) => ({ start: { seconds: s }, end: { seconds: e } }));
    return {
      name, id: 100 + nextId++, clips: coll(clips),
      isLocked: () => locked,
      overwriteClip(item: { path: string }, t: number) {
        if (locked) return false;
        // Premiere rounds a clip's length down to whole frames (25 fps here).
        const len = Math.floor((durations[item.path] ?? 1) * 25 + 1e-6) / 25;
        clips.push({ start: { seconds: t }, end: { seconds: t + len } });
        return true;
      },
    };
  }
  const tracks = (o.tracks ?? [{ name: "Audio 1" }]).map((t) => track(t.name, t.clips, t.locked));
  const item = (path: string) => ({
    type: 1, name: path.split("/").pop(), path,
    getMediaPath: () => path,
    getInPoint: () => ({ seconds: 0 }),
    getOutPoint: () => ({ seconds: durations[path] ?? 1 }),
  });
  const bin = (name: string) => {
    const kids: unknown[] = [];
    return { type: 2, name, children: coll(kids), kids };
  };
  const seq = {
    getSettings: () => ({ videoFrameRate: { seconds: 1 / 25 } }),
    getPlayerPosition: () => ({ seconds: o.playhead ?? 10 }),
    audioTracks: coll(tracks),
    captionTracks: coll(captionTracks),
    createCaptionTrack(it: { path: string }, at: number, format: number) {
      captions.push({ item: it.path, at, format });
      captionTracks.push({});
      return true;
    },
  };
  const app = {
    version: "26.5.2",
    project: {
      name: "Kitchen Tour.prproj", documentID: "doc-1", path: "/p/Kitchen Tour.prproj",
      activeSequence: seq as typeof seq | null,
      rootItem: {
        children: coll(rootChildren),
        createBin(name: string) { const b = bin(name); rootChildren.push(b); return b; },
      },
      importFiles(paths: string[], _s: boolean, target: { kids: unknown[] }) { paths.forEach((p) => target.kids.push(item(p))); return true; },
    },
    enableQE() {},
  };
  const qe = { project: { getActiveSequence: () => ({ addTracks() { tracks.push(track("Audio " + (tracks.length + 1))); } }) } };
  const ctx: Record<string, unknown> = { app, qe, Sequence: { CAPTION_FORMAT_SUBTITLE: 4 } };
  runInNewContext(SRC, ctx);
  const call = (fn: string, args?: unknown) => JSON.parse((ctx.HiggsVO as Record<string, (a?: unknown) => string>)[fn](args));
  return { call, tracks, captions, app };
}

test("info names the project and says whether a sequence is open", () => {
  const p = premiere();
  assert.deepEqual(p.call("info"), { project: "Kitchen Tour", id: "doc-1", hasSequence: true, version: "26.5.2" });
  p.app.project.activeSequence = null;
  assert.equal(p.call("info").hasSequence, false);
});

test("a missing track is added and named, and the clips go back to back from the playhead", () => {
  const p = premiere({ playhead: 10, durations: { "/m/a.wav": 2, "/m/b.wav": 1.5 } });
  const r = p.call("place", { takes: [{ path: "/m/a.wav", seconds: 2 }, { path: "/m/b.wav", seconds: 1.5 }], track: "Higgs VO", bin: "Higgs VoiceOver" });
  assert.equal(r.ok, true);
  assert.equal(p.tracks.length, 2);
  assert.equal(p.tracks[1].name, "Higgs VO");
  assert.deepEqual(r.starts, [10, 12]);
  assert.deepEqual(r.ends, [12, 13.48]);   // 1.5 s is 37.5 frames; Premiere keeps 37
  assert.equal(r.pushed, false);
  assert.equal(r.fps, 25);
  assert.equal(r.track, "A2");
});

test("a track chosen by number is used as it is, and one the sequence lacks is refused", () => {
  const p = premiere({ playhead: 4, tracks: [{ name: "Audio 1" }, { name: "Audio 2", clips: [[2, 6]] }], durations: { "/m/a.wav": 1 } });
  const r = p.call("place", { takes: [{ path: "/m/a.wav", seconds: 1 }], track: "Higgs VO", index: 1, bin: "Higgs VoiceOver" });
  assert.equal(r.ok, true);
  assert.equal(r.track, "A2");
  assert.deepEqual(r.starts, [6]);
  assert.equal(p.tracks.length, 2);
  const none = p.call("place", { takes: [{ path: "/m/a.wav", seconds: 1 }], track: "Higgs VO", index: 5, bin: "Higgs VoiceOver" });
  assert.equal(none.error, "This sequence has no A6 track. Choose another track in Settings.");
  assert.deepEqual(p.call("tracks"), ["Audio 1", "Audio 2"]);
});

test("each clip starts exactly where Premiere ended the one before (no frame gaps)", () => {
  const p = premiere({ playhead: 0, durations: { "/m/a.wav": 1.861, "/m/b.wav": 1.571, "/m/c.wav": 2.003 } });
  const r = p.call("place", { takes: [{ path: "/m/a.wav", seconds: 1.861 }, { path: "/m/b.wav", seconds: 1.571 }, { path: "/m/c.wav", seconds: 2.003 }], track: "Higgs VO", bin: "Higgs VoiceOver" });
  assert.equal(r.ok, true);
  for (let i = 1; i < r.starts.length; i++) assert.ok(Math.abs(r.starts[i] - r.ends[i - 1]) < 1e-9, `gap before clip ${i + 1}: ${r.ends[i - 1]} → ${r.starts[i]}`);
});

test("clips reaching past the playhead push the run after them; nothing is overwritten", () => {
  const p = premiere({ playhead: 10, tracks: [{ name: "Higgs VO", clips: [[8, 11.5]] }], durations: { "/m/a.wav": 2 } });
  const r = p.call("place", { takes: [{ path: "/m/a.wav", seconds: 2 }], track: "Higgs VO", bin: "Higgs VoiceOver" });
  assert.equal(r.ok, true);
  assert.deepEqual(r.starts, [11.5]);
  assert.equal(r.pushed, true);
});

test("a locked track is refused with what to do", () => {
  const p = premiere({ tracks: [{ name: "Higgs VO", locked: true }] });
  const r = p.call("place", { takes: [{ path: "/m/a.wav", seconds: 1 }], track: "Higgs VO", bin: "Higgs VoiceOver" });
  assert.equal(r.ok, false);
  assert.equal(r.error, "A1 is locked. Unlock it and place again.");
});

test("no sequence: say so", () => {
  const p = premiere();
  p.app.project.activeSequence = null;
  assert.equal(p.call("place", { takes: [], track: "Higgs VO", bin: "Higgs VoiceOver" }).error, "No sequence is open.");
});

test("captions: the .srt is imported into the bin and becomes a caption track at the given time", () => {
  const p = premiere();
  const r = p.call("captions", { srt: "/m/a_subtitles.srt", at: 12.4, bin: "Higgs VoiceOver" });
  assert.deepEqual(r, { ok: true });
  assert.deepEqual(p.captions, [{ item: "/m/a_subtitles.srt", at: 12.4, format: 4 }]);
});

test("files already in the bin are not imported twice", () => {
  const p = premiere();
  p.call("importToBin", { paths: ["/m/a.wav"], bin: "Higgs VoiceOver" });
  p.call("importToBin", { paths: ["/m/a.wav", "/m/b.wav"], bin: "Higgs VoiceOver" });
  const bin = (p.app.project.rootItem.children as unknown as Record<string, { kids: unknown[] }>)["0"];
  assert.equal(bin.kids.length, 2);
});

test("a script error comes back as a message the panel can show", () => {
  const p = premiere();
  (p.app.project as unknown as { importFiles: () => never }).importFiles = () => { throw new Error("boom"); };
  const r = p.call("importToBin", { paths: ["/m/x.wav"], bin: "Higgs VoiceOver" });
  assert.equal(r.ok, false);
  assert.match(r.error, /^Premiere stopped with an error: Error: boom/);
});
