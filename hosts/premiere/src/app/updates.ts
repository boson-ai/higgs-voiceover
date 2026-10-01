// Is there a newer Premiere build on GitHub?
//
// The repository's "latest" release belongs to whichever host shipped last
// (Resolve 1.0.0 clients read it), so this looks through recent releases for
// the newest one that carries a Premiere package. Premiere releases are
// published with "make latest" off for that reason. Nothing is sent but the
// request itself.

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

/** Release files are named for the app and host ("Higgs-VoiceOver-1.1.0-Premiere-Pro.ccx"); GitHub may rewrite spaces. */
export function isPremiereAsset(name: string): boolean {
  const key = name.toLowerCase().replace(/[^a-z0-9]/g, "");
  return key.startsWith("higgsvoiceover") && key.includes("premiere") && key.endsWith("ccx");
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

export async function checkForUpdate(http: Http, current: string): Promise<UpdateCheck> {
  const res = await http.request({
    method: "GET",
    url: `https://api.github.com/repos/${UPDATE_REPO}/releases?per_page=30`,
    headers: { Accept: "application/vnd.github+json" },
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
    const asset = (r.assets ?? []).find((a) => isPremiereAsset(a.name));
    if (!asset) continue;
    const version = String(r.tag_name ?? r.name ?? "").replace(/^[^\d]*/, "");
    if (!best || isNewer(version, best.version)) best = { version, page: r.html_url, asset: asset.browser_download_url };
  }
  if (!best || !isNewer(best.version, current)) return { ok: true, latest: null };
  return { ok: true, latest: best.version, page: best.page, asset: best.asset };
}
