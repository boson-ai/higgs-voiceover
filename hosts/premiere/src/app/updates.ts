// Is there a newer Premiere build on GitHub?
//
// Each release (vX.Y.Z) carries an installer for every editor, all at the
// same version. This looks through recent releases for the newest one that
// carries a package this build can install, so a release without one is
// skipped rather than offered. Nothing is sent but the request itself.

import type { Http } from "../host/host.ts";

export const UPDATE_REPO = "boson-ai/higgs-voiceover";

export interface UpdateCheck {
  ok: boolean;
  /** Newer than the running version, or null when up to date. */
  latest: string | null;
  page?: string;
  asset?: string;
  error?: string;
}

/**
 * Release files are named for the app, host and OS
 * ("Higgs-VoiceOver-1.0.0-Premiere-Pro-macOS.pkg"); GitHub may rewrite spaces.
 * `kinds` is the package types this build installs from, best first: the CEP
 * build takes the macOS installer or the .zxp, the UXP build a .ccx.
 */
export function isPremiereAsset(name: string, kinds: readonly string[] = ["ccx"]): boolean {
  const key = name.toLowerCase().replace(/[^a-z0-9]/g, "");
  return key.startsWith("higgsvoiceover") && key.includes("premiere") && kinds.some((k) => key.endsWith(k));
}

export function versionTuple(v: string): [number, number, number] {
  const m = /(\d+)\.?(\d*)\.?(\d*)/.exec(v) ?? [];
  return [Number(m[1]) || 0, Number(m[2]) || 0, Number(m[3]) || 0];
}

export function isNewer(candidate: string, current: string): boolean {
  const a = versionTuple(candidate), b = versionTuple(current);
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i];
  return false;
}

interface Release { tag_name?: string; name?: string; html_url?: string; draft?: boolean; prerelease?: boolean; assets?: { name: string; browser_download_url: string }[] }

export async function checkForUpdate(http: Http, current: string, kinds: readonly string[] = ["ccx"]): Promise<UpdateCheck> {
  const res = await http.request({
    method: "GET",
    url: `https://api.github.com/repos/${UPDATE_REPO}/releases?per_page=30`,
    // GitHub refuses API requests without a User-Agent (403); a browser adds
    // one, Node - which the CEP build's requests go through - does not.
    headers: { Accept: "application/vnd.github+json", "User-Agent": `HiggsVoiceOver/${current}` },
    timeoutMs: 20_000,
  });
  // In GitHub's words, short: the row has room for a few words.
  if (res.status === 404) return { ok: true, latest: null };
  if (res.status === 403 || res.status === 429) return { ok: false, latest: null, error: "GitHub is busy, try again later" };
  if (res.status === 0) return { ok: false, latest: null, error: "couldn't reach GitHub" };
  if (res.status !== 200) return { ok: false, latest: null, error: "couldn't check for updates" };
  let releases: Release[];
  try { releases = JSON.parse(res.text); } catch { return { ok: false, latest: null, error: "couldn't check for updates" }; }
  let best: { version: string; page?: string; asset: string } | null = null;
  for (const r of Array.isArray(releases) ? releases : []) {
    if (r.draft || r.prerelease) continue;
    // The best package this build can install, in the order given.
    const asset = kinds.map((k) => (r.assets ?? []).find((a) => isPremiereAsset(a.name, [k]))).find(Boolean);
    if (!asset) continue;
    const version = String(r.tag_name ?? r.name ?? "").replace(/^[^\d]*/, "");
    if (!best || isNewer(version, best.version)) best = { version, page: r.html_url, asset: asset.browser_download_url };
  }
  if (!best || !isNewer(best.version, current)) return { ok: true, latest: null };
  return { ok: true, latest: best.version, page: best.page, asset: best.asset };
}
