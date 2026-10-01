// The Premiere build's own code: placing, subtitles to the bin, the update
// check, retries, settings and logs — on the preview's stand-in host.

import { test } from "node:test";
import { strict as assert } from "node:assert";
import { createMockHost, toneWav } from "../preview/mock-host.ts";
import { startLog } from "../src/app/log.ts";
import { openStore } from "../src/app/store.ts";
import { Client } from "../src/app/client.ts";
import { placeTakes, subtitleFile } from "../src/app/placing.ts";
import { checkForUpdate, isNewer, isPremiereAsset } from "../src/app/updates.ts";
import { startAfter } from "../src/host/rules.ts";
import type { HttpRequest, HttpResponse, Take } from "../src/host/host.ts";

const video = {
  addEventListener() {}, pause() {}, play() { return Promise.resolve(); },
  currentTime: 0, duration: NaN, src: "",
} as unknown as HTMLVideoElement;

const enc = (s: string) => new TextEncoder().encode(s);
const reply = (status: number, body: string): HttpResponse => ({ status, bytes: enc(body), text: body });

async function setup(o: Parameters<typeof createMockHost>[1] = {}) {
  const host = createMockHost(video, { key: "bai-test", ...o });
  const log = await startLog(host.files, "test");
  return { host, log };
}

function take(text: string, seconds: number, words?: { word: string; start: number; end: number }[]): Take {
  return { path: `/Users/you/Movies/Higgs VoiceOver/${text.slice(0, 5)}.wav`, seconds, text, words, pause: 0.4 };
}

// ------------------------------------------------------------------ placing

test("a run starts at the playhead, or after clips that reach past it", () => {
  assert.equal(startAfter(10, []), 10);
  assert.equal(startAfter(10, [{ start: 0, end: 4 }]), 10);
  assert.equal(startAfter(10, [{ start: 8, end: 12.5 }]), 12.5);
  assert.equal(startAfter(10, [{ start: 20, end: 25 }]), 25);
});

test("no sequence: say so, and that the clips are already in the bin", async () => {
  const { host, log } = await setup({ sequence: false });
  const one = await placeTakes(host, log, [take("Hello there.", 1)], { trackName: "Higgs VO", subtitles: false, split: "short", mode: "all" });
  assert.equal(one.ok, false);
  assert.equal(one.message, "Open a sequence to place this clip. It's already in your bin.");
  const two = await placeTakes(host, log, [take("A.", 1), take("B.", 1)], { trackName: "Higgs VO", subtitles: false, split: "short", mode: "all" });
  assert.equal(two.message, "Open a sequence to place these clips. They're already in your bin.");
});

test("placed messages name the track and where the run went", async () => {
  const { host, log } = await setup();
  const first = await placeTakes(host, log, [take("Hello there.", 2)], { trackName: "Higgs VO", subtitles: false, split: "short", mode: "one" });
  assert.equal(first.message, "Placed on “Higgs VO” at the playhead.");
  const next = await placeTakes(host, log, [take("A.", 1), take("B.", 1)], { trackName: "Higgs VO", subtitles: false, split: "short", mode: "all" });
  assert.equal(next.message, "Placed 2 clips on “Higgs VO”, starting after the clip at the playhead.");
});

test("subtitles are written from the first clip's start and imported into the bin", async () => {
  const { host, log } = await setup();
  const words = [{ word: "Hello", start: 0.5, end: 0.9 }, { word: "there", start: 1.0, end: 1.4 }];
  const out = await placeTakes(host, log, [take("Hello there.", 2, words)], { trackName: "Higgs VO", subtitles: true, split: "short", mode: "auto" });
  assert.equal(out.ok, true);
  assert.match(out.message, /^Placed on “Higgs VO” at the playhead\. Subtitles are in the bin — drag them to the start of the clip\.$/);
  const srt = [...host.fs.entries()].find(([k]) => k.endsWith(".srt"));
  assert.ok(srt, "an .srt was written");
  // The voice starts half a second into the clip, and so does the subtitle.
  assert.match(new TextDecoder().decode(srt![1]), /^1\n00:00:00,480 --> /);
});

test("a take without word timings becomes one subtitle the length of its clip", () => {
  const f = subtitleFile([take("Una línea sin tiempos.", 3)], [10], [13], 25, "short");
  assert.equal(f.whole, 1);
  assert.equal(f.cues, 1);
  assert.match(f.text, /^1\n00:00:00,000 --> 00:00:03,000\nUna línea sin tiempos\.\n/);
});

// ------------------------------------------------------------------ updates

test("Premiere packages are told apart from other hosts' files", () => {
  assert.ok(isPremiereAsset("Higgs-VoiceOver-1.1.0-Premiere-Pro.ccx"));
  assert.ok(isPremiereAsset("Higgs.VoiceOver.1.1.0.Premiere.Pro.ccx"));
  assert.ok(!isPremiereAsset("Higgs-VoiceOver-1.0.0-DaVinci-Resolve-macOS.pkg"));
  assert.ok(!isPremiereAsset("Higgs-VoiceOver-1.0.0-DaVinci-Resolve-macOS.lua"));
  assert.ok(isNewer("1.0.10", "1.0.9"));
  assert.ok(!isNewer("1.0.0", "1.0.0"));
});

test("the update check finds the newest Premiere release, skipping other hosts and pre-releases", async () => {
  const releases = [
    { tag_name: "v1.2.0", assets: [{ name: "Higgs-VoiceOver-1.2.0-DaVinci-Resolve-macOS.pkg", browser_download_url: "r" }] },
    { tag_name: "premiere-v0.3.0", prerelease: true, assets: [{ name: "Higgs-VoiceOver-0.3.0-Premiere-Pro.ccx", browser_download_url: "beta" }] },
    { tag_name: "premiere-v0.2.0", html_url: "page", assets: [{ name: "Higgs-VoiceOver-0.2.0-Premiere-Pro.ccx", browser_download_url: "ccx" }] },
  ];
  const http = { request: async (_r: HttpRequest) => reply(200, JSON.stringify(releases)) };
  assert.deepEqual(await checkForUpdate(http, "0.1.0"), { ok: true, latest: "0.2.0", page: "page", asset: "ccx" });
  assert.deepEqual(await checkForUpdate(http, "0.2.0"), { ok: true, latest: null });
  assert.equal((await checkForUpdate({ request: async () => reply(403, "") }, "0.1.0")).error, "GitHub is busy, try again later");
  assert.equal((await checkForUpdate({ request: async () => ({ status: 0, bytes: new Uint8Array(0), text: "" }) }, "0.1.0")).error, "couldn't reach GitHub");
});

// ------------------------------------------------------------------ client

test("speech is retried after a 429 and the key never leaves the Authorization header", async () => {
  const { log } = await setup();
  const seen: HttpRequest[] = [];
  let calls = 0;
  const http = {
    request: async (r: HttpRequest) => {
      seen.push(r);
      calls++;
      return calls < 3 ? reply(429, JSON.stringify({ error: { message: "slow down" } })) : { status: 200, bytes: toneWav(0.5), text: "" };
    },
  };
  const waits: number[] = [];
  const client = new Client(http, () => "bai-secret", "test", log, async (ms) => { waits.push(ms); });
  const res = await client.speech({ text: "Hello.", voice: "nora", format: "wav" });
  assert.equal(res.ok, true);
  assert.deepEqual(waits, [2000, 5000]);
  assert.equal(seen[0].headers?.Authorization, "Bearer bai-secret");
  assert.ok(!seen[0].url.includes("bai-secret") && !String(seen[0].body).includes("bai-secret"));
});

test("a request without a key is refused before it is sent", async () => {
  const { log } = await setup();
  let sent = false;
  const client = new Client({ request: async () => { sent = true; return reply(200, "{}"); } }, () => "", "test", log);
  const res = await client.speech({ text: "Hello.", voice: "nora", format: "wav" });
  assert.equal(res.ok, false);
  assert.equal(sent, false);
});

// ------------------------------------------------------------------ settings and logs

test("settings start from the defaults, and drafts are kept per project", async () => {
  const { host } = await setup();
  const store = await openStore(host.files, host.secrets);
  assert.equal(store.cfg.vo_track_name, "Higgs VO");
  assert.equal(store.cfg.auto_place, true);
  assert.equal(store.cfg.output_dir, "/Users/you/Movies/Higgs VoiceOver");
  assert.equal(store.outputDir("Kitchen Tour"), "/Users/you/Movies/Higgs VoiceOver/Kitchen_Tour");
  assert.equal(store.key, "bai-test");
  await store.saveDraft("p1", "Line one", "chloe");
  assert.deepEqual(await store.loadDraft("p1"), { text: "Line one", voice: "chloe" });
  assert.equal(await store.loadDraft("p2"), null);
});

test("an older settings file is migrated, and a damaged one is kept aside", async () => {
  const { host } = await setup();
  await host.files.write("/preview/data/config.json", JSON.stringify({ schema: 3, auto_place: false, pause_ms: 240 }));
  const store = await openStore(host.files, host.secrets);
  assert.equal(store.cfg.auto_place, true);
  assert.equal(store.cfg.pause_ms, 400);
  await host.files.write("/preview/data/config.json", "{ not json");
  await openStore(host.files, host.secrets);
  assert.equal(await host.files.readText("/preview/data/config.json.bad"), "{ not json");
});

test("logs keep the ten most recent sessions", async () => {
  const host = createMockHost(video, {});
  for (let i = 0; i < 12; i++) await host.files.write(`/preview/data/logs/higgs-vo-2026010${i % 10}-0000${String(i).padStart(2, "0")}.log`, "x");
  const log = await startLog(host.files, "test");
  log.info("hello", { path: log.q(log.pathSafe("/Users/you/Movies/a.wav")) });
  await new Promise((r) => setTimeout(r, 10));
  const names = (await host.files.list("/preview/data/logs")).filter((n) => n.endsWith(".log"));
  assert.equal(names.length, 10);
  assert.match((await host.files.readText(log.path)) ?? "", /info   hello  path=‹~\/Movies\/a\.wav›/);
});
