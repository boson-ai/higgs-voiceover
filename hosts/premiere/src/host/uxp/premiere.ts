// Premiere integration: the project's bin, and placing clips on a named
// audio track at the playhead.
//
// Written against the `premierepro` UXP API of Premiere 26.5 from Adobe's
// reference and samples; facts marked UNVERIFIED have not been seen in a
// running Premiere yet. What the API is known to do, and how it differs from
// Resolve's:
//
//   * Every getter is async; every edit is an Action committed inside
//     `project.lockedAccess(() => project.executeTransaction(...))`, and
//     nothing may be awaited inside either callback (26.3+). One transaction
//     is one undo step, named here.
//   * `importFiles` answers only true/false. The imported item is found
//     afterwards by its media path in the bin.
//   * There is no "add track" call. Placing at an audio track index one past
//     the last makes a new track (Adobe's SequenceEditor reference); it is
//     then named in a second transaction. UNVERIFIED for overwrite edits.
//   * There is no "is this track locked" getter. A placement onto a locked
//     track is caught by reading the track back, as every placement is:
//     Premiere has been reported to put a clip on another track silently
//     when channel layouts differ.
//   * More than ~50 actions in one transaction hangs Premiere (forum
//     reports), so long runs are committed in batches.

import type { premierepro, Project, FolderItem, ProjectItem, Sequence, AudioTrack } from "@adobe/premierepro";
import type { PlaceResult, Timeline } from "../host.ts";
import { startAfter, type Span } from "../rules.ts";

const ppro = require("premierepro") as premierepro;

export const BIN_NAME = "Higgs VoiceOver";
const BATCH = 40;

async function activeProject(): Promise<Project | null> {
  try { return (await ppro.Project.getActiveProject()) ?? null; } catch { return null; }
}

async function activeSequence(project: Project): Promise<Sequence | null> {
  try { return (await project.getActiveSequence()) ?? null; } catch { return null; }
}

function commit(project: Project, undo: string, build: (add: (a: unknown) => void) => void): boolean {
  let ok = false;
  project.lockedAccess(() => {
    ok = project.executeTransaction((compound) => {
      build((a) => compound.addAction(a as never));
    }, undo);
  });
  return ok;
}

async function findBin(project: Project, name: string): Promise<FolderItem | null> {
  const root = await project.getRootItem();
  for (const item of await root.getItems()) {
    if (item.type === ppro.ProjectItem.TYPE_BIN && item.name === name) return ppro.FolderItem.cast(item);
  }
  return null;
}

async function ensureBin(project: Project): Promise<FolderItem | null> {
  const existing = await findBin(project, BIN_NAME);
  if (existing) return existing;
  const root = await project.getRootItem();
  commit(project, "Higgs VoiceOver: add bin", (add) => add(root.createBinAction(BIN_NAME, false)));
  // The action returns nothing; the bin is found by name afterwards.
  return findBin(project, BIN_NAME);
}

async function itemsByPath(bin: FolderItem): Promise<Map<string, ProjectItem>> {
  const out = new Map<string, ProjectItem>();
  for (const item of await bin.getItems()) {
    if (item.type !== ppro.ProjectItem.TYPE_CLIP) continue;
    try {
      const path = await ppro.ClipProjectItem.cast(item).getMediaFilePath();
      if (path) out.set(path.replace(/\\/g, "/").toLowerCase(), item);
    } catch { /* not a file-backed clip */ }
  }
  return out;
}

async function importInto(project: Project, bin: FolderItem, paths: string[]): Promise<Map<string, ProjectItem> | string> {
  let have = await itemsByPath(bin);
  const missing = paths.filter((p) => !have.has(p.replace(/\\/g, "/").toLowerCase()));
  if (missing.length > 0) {
    const ok = await project.importFiles(missing, true, ppro.ProjectItem.cast(bin), false);
    if (!ok) return "Premiere would not import the clip.";
    have = await itemsByPath(bin);
  }
  return have;
}

interface TrackRef { index: number; track: AudioTrack | null }

async function findTrack(seq: Sequence, name: string): Promise<TrackRef & { count: number }> {
  const count = await seq.getAudioTrackCount();
  for (let i = 0; i < count; i++) {
    const t = await seq.getAudioTrack(i);
    if (t && t.name === name) return { index: i, track: t, count };
  }
  return { index: count, track: null, count };
}

async function spans(track: AudioTrack | null): Promise<Span[]> {
  if (!track) return [];
  const out: Span[] = [];
  for (const item of track.getTrackItems(ppro.Constants.TrackItemType.CLIP, false)) {
    out.push({ start: (await item.getStartTime()).seconds, end: (await item.getEndTime()).seconds });
  }
  return out.sort((a, b) => a.start - b.start);
}

export const timeline: Timeline = {
  async projectName() {
    const p = await activeProject();
    return p ? p.name.replace(/\.prproj$/i, "") : "";
  },
  async projectId() {
    const p = await activeProject();
    return p ? p.guid.toString() : "";
  },
  async hasSequence() {
    const p = await activeProject();
    return !!(p && (await activeSequence(p)));
  },
  async binName() {
    return BIN_NAME;
  },
  async importToBin(paths) {
    const project = await activeProject();
    if (!project) return { ok: false, error: "No project is open." };
    const bin = await ensureBin(project);
    if (!bin) return { ok: false, error: "Premiere would not make the “" + BIN_NAME + "” bin." };
    const got = await importInto(project, bin, paths);
    return typeof got === "string" ? { ok: false, error: got } : { ok: true };
  },
  async place(takes, trackName) {
    const fail = (error: string, fps = 0): PlaceResult => ({ ok: false, placed: 0, starts: [], ends: [], pushed: false, fps, error });
    const project = await activeProject();
    if (!project) return fail("No project is open.");
    const seq = await activeSequence(project);
    if (!seq) return fail("No sequence is open.");
    const rate = (await seq.getSettings()).getVideoFrameRate();
    const fps = rate.value || 24;
    const frame = 1 / fps;

    const bin = await ensureBin(project);
    if (!bin) return fail("Premiere would not make the “" + BIN_NAME + "” bin.", fps);
    const items = await importInto(project, bin, takes.map((t) => t.path));
    if (typeof items === "string") return fail(items, fps);

    // Everything is read before the edit: nothing may be awaited inside it.
    const found = await findTrack(seq, trackName);
    const playhead = (await seq.getPlayerPosition()).alignToFrame(rate).seconds;
    const start = startAfter(playhead, await spans(found.track));
    const plan: { item: ProjectItem; at: number; seconds: number }[] = [];
    let at = start;
    for (const t of takes) {
      const item = items.get(t.path.replace(/\\/g, "/").toLowerCase());
      if (!item) return fail("Premiere imported the clip but it is not in the bin.", fps);
      let seconds = t.seconds;
      try { seconds = (await ppro.ClipProjectItem.cast(item).getMedia()).getDuration().seconds || seconds; } catch { /* keep ours */ }
      plan.push({ item, at, seconds });
      // The next clip starts on the frame after this one ends.
      at = Math.ceil((at + seconds) / frame - 1e-6) * frame;
    }

    const editor = ppro.SequenceEditor.getEditor(seq);
    for (let i = 0; i < plan.length; i += BATCH) {
      const chunk = plan.slice(i, i + BATCH);
      const ok = commit(project, plan.length === 1 ? "Higgs VoiceOver: place clip" : "Higgs VoiceOver: place clips", (add) => {
        for (const p of chunk) {
          // The video index is required even for audio; a WAV has no video.
          add(editor.createOverwriteItemAction(p.item, ppro.TickTime.createWithSeconds(p.at), 0, found.index));
        }
      });
      if (!ok) return fail("Premiere did not place the clip.", fps);
    }

    // A new track gets its name now that it exists.
    let track = found.track;
    if (!track) {
      const count = await seq.getAudioTrackCount();
      if (count > found.count) {
        track = await seq.getAudioTrack(found.index);
        const made = track;
        if (made) commit(project, "Higgs VoiceOver: name track", (add) => add(made.createSetNameAction(trackName)));
      }
    }

    // Trust the timeline, not the return value.
    const landed = await spans(track);
    const starts: number[] = [], ends: number[] = [];
    for (const p of plan) {
      const hit = landed.find((s) => Math.abs(s.start - p.at) < frame / 2);
      if (!hit) {
        const placed = starts.length;
        const why = `Premiere did not place the clip on “${trackName}”. The track may be locked.`;
        return { ok: false, placed, starts, ends, pushed: start > playhead + frame / 2, fps, error: why };
      }
      starts.push(hit.start);
      ends.push(hit.end);
    }
    return { ok: true, placed: plan.length, starts, ends, pushed: start > playhead + frame / 2, fps };
  },
};
