// The CEP build's timeline: calls into cep/jsx/host.jsx (ExtendScript)
// through CEP's evalScript, one JSON object in and one out.

import type { PlaceResult, Timeline } from "../host.ts";

export const BIN_NAME = "Higgs VoiceOver";

/** Run HiggsVO.<fn>(args) in Premiere's ExtendScript and parse what it returns. */
export function jsx<T>(fn: string, args?: unknown): Promise<T | null> {
  return new Promise((resolve) => {
    const bridge = window.__adobe_cep__;
    if (!bridge) { resolve(null); return; }
    // JSON is an ES3 object literal, apart from two line separators ES3 strings may not hold.
    const arg = args === undefined ? "" : JSON.stringify(args).replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");
    bridge.evalScript(`HiggsVO.${fn}(${arg})`, (out) => {
      try { resolve(JSON.parse(out) as T); } catch { resolve(null); }   // "EvalScript error." and the like
    });
  });
}

interface Info { project: string; id: string; hasSequence: boolean; version: string }
const fallback = (error: string): PlaceResult => ({ ok: false, placed: 0, starts: [], ends: [], pushed: false, fps: 0, error });

export const timeline: Timeline = {
  async projectName() { return (await jsx<Info>("info"))?.project ?? ""; },
  async projectId() { return (await jsx<Info>("info"))?.id ?? ""; },
  async hasSequence() { return (await jsx<Info>("info"))?.hasSequence ?? false; },
  async binName() { return BIN_NAME; },
  async importToBin(paths) {
    return (await jsx<{ ok: boolean; error?: string }>("importToBin", { paths, bin: BIN_NAME })) ?? { ok: false, error: "Premiere did not answer." };
  },
  async place(takes, trackName) {
    return (await jsx<PlaceResult>("place", { takes, track: trackName, bin: BIN_NAME })) ?? fallback("Premiere did not answer.");
  },
  async addCaptions(srt, at) {
    return (await jsx<{ ok: boolean; error?: string }>("captions", { srt, at, bin: BIN_NAME })) ?? { ok: false, error: "Premiere did not answer." };
  },
};
