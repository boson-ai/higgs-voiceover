// A stand-in Premiere for the browser preview: files in memory, a fake
// project with one sequence, and a fake Boson that answers with a short tone
// and word timings. Nothing leaves the browser.
//
// The preview shows layout and behaviour; it is not Premiere. Controls are
// the browser's, fonts are the browser's, and UXP's CSS limits are enforced
// by scripts/lint-css.mjs rather than by rendering here.

import type { Host, HttpRequest, HttpResponse, PlaceResult, Recorder, Take, TrackTarget } from "../src/host/host.ts";
import { createMediaPlayer } from "../src/host/player.ts";

const enc = (s: string) => new TextEncoder().encode(s);
const dec = (b: Uint8Array) => new TextDecoder().decode(b);

/** A mono 16-bit WAV: a soft tone shaped like speech, `seconds` long. */
export function toneWav(seconds: number, rate = 24000): Uint8Array {
  const n = Math.floor(seconds * rate);
  const buf = new ArrayBuffer(44 + n * 2);
  const v = new DataView(buf);
  const str = (o: number, s: string) => [...s].forEach((c, i) => v.setUint8(o + i, c.charCodeAt(0)));
  str(0, "RIFF"); v.setUint32(4, 36 + n * 2, true); str(8, "WAVE"); str(12, "fmt ");
  v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
  v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
  str(36, "data"); v.setUint32(40, n * 2, true);
  for (let i = 0; i < n; i++) {
    const t = i / rate;
    const env = Math.max(0, Math.sin(Math.PI * ((t * 3.1) % 1))) * 0.25;
    v.setInt16(44 + i * 2, Math.round(Math.sin(2 * Math.PI * 180 * t) * env * 32767), true);
  }
  return new Uint8Array(buf);
}

const b64 = (b: Uint8Array) => { let s = ""; for (const x of b) s += String.fromCharCode(x); return btoa(s); };

export interface MockOptions {
  key?: string;
  theme?: string;
  project?: string;
  sequence?: boolean;
  latest?: string;
  failSpeech?: number;
  /** Act as the CEP build: a microphone and native captions. */
  cep?: boolean;
  /** The element for the second player (voice samples); the first one if absent. */
  samplesMedia?: HTMLVideoElement;
}

/** A stand-in microphone: a voice-like tone, so the dialog can be tried without a real input. */
function mockRecorder(): Recorder {
  let started = 0, capturing = false;
  const seconds = () => (capturing ? (Date.now() - started) / 1000 : 0);
  return {
    inputs: async () => [
      { id: "default", label: "System default" },
      { id: "mbp", label: "MacBook Pro Microphone" },
      { id: "usb", label: "Insta360 Link 2C Pro" },
    ],
    use() {},
    open: async () => ({ ok: true }),
    begin() { started = Date.now(); capturing = true; },
    level: () => (capturing ? 0.35 + 0.3 * Math.abs(Math.sin(Date.now() / 180)) : 0.02),
    seconds,
    async stop() {
      const s = seconds();
      capturing = false;
      const wav = toneWav(s);
      return wav.slice(44);
    },
    cancel() { capturing = false; },
  };
}

export function createMockHost(media: HTMLVideoElement, o: MockOptions = {}): Host & { placed: PlaceResult[]; fs: Map<string, Uint8Array> } {
  const fs = new Map<string, Uint8Array>();
  const urls = new Map<string, string>();
  const secrets = new Map<string, string>(o.key ? [["boson_api_key", o.key]] : []);
  const placed: PlaceResult[] = [];
  const bin = new Set<string>();
  const tracks: { name: string; spans: { start: number; end: number }[] }[] =
    ["Audio 1", "Audio 2", "Audio 3"].map((name) => ({ name, spans: [] }));
  let theme = o.theme ?? "darkest";
  const themeListeners: ((t: string) => void)[] = [];
  let speechCalls = 0;

  const join = (...p: string[]) => p.filter(Boolean).join("/").replace(/\/+/g, "/");
  const urlFor = (path: string) => {
      if (!urls.has(path)) urls.set(path, URL.createObjectURL(new Blob([(fs.get(path) ?? new Uint8Array(0)) as BlobPart], { type: "audio/wav" })));
      return urls.get(path)!;
  };

  async function http(req: HttpRequest): Promise<HttpResponse> {
    await new Promise((r) => setTimeout(r, req.url.includes("/audio/speech") ? 700 : 300));
    const reply = (status: number, body: string | Uint8Array): HttpResponse => {
      const bytes = typeof body === "string" ? enc(body) : body;
      return { status, bytes, text: typeof body === "string" ? body : "" };
    };
    if (req.url.includes("api.github.com")) {
      const v = o.latest ?? "0.1.0";
      return reply(200, JSON.stringify([{ tag_name: `premiere-v${v}`, html_url: "https://github.com/boson-ai/higgs-voiceover/releases", assets: [{ name: `Higgs-VoiceOver-${v}-Premiere-Pro.ccx`, browser_download_url: "https://example.invalid/x.ccx" }] }]));
    }
    const auth = req.headers?.Authorization ?? "";
    if (!auth.endsWith(secrets.get("boson_api_key") ?? "∅") && !auth.includes("bai-preview")) return reply(401, JSON.stringify({ error: { message: "invalid api key" } }));
    if (req.url.endsWith("/audio/voices") && req.method === "GET") return reply(200, JSON.stringify({ data: [] }));
    if (req.url.endsWith("/audio/voices") && req.method === "POST") return reply(200, JSON.stringify({ id: "voice_preview_" + Date.now(), description: JSON.parse(req.body ?? "{}").description }));
    if (req.url.endsWith("/audio/speech")) {
      speechCalls++;
      if (o.failSpeech && speechCalls === o.failSpeech) return reply(429, JSON.stringify({ error: { message: "rate limited" } }));
      const body = JSON.parse(req.body ?? "{}");
      const words = String(body.input ?? "").replace(/<\|[^|]*\|>/g, " ").split(/\s+/).filter(Boolean);
      const seconds = Math.max(1, words.length * 0.32);
      const wav = toneWav(seconds);
      if (!body.timestamps) return reply(200, wav);
      let t = 0.1;
      const ts = words.map((w) => { const s = t; t += 0.3; return { word: w.replace(/[^\p{L}\p{N}']/gu, ""), start: s, end: s + 0.26 }; });
      return reply(200, JSON.stringify({ audio: b64(wav), response_format: "wav", input: body.input, timestamps: ts }));
    }
    return reply(404, "{}");
  }

  return {
    placed,
    fs,
    files: {
      dataDir: "/preview/data",
      home: "/Users/you",
      mediaDir: "/Users/you/Movies",
      sep: "/",
      join,
      basename: (p) => p.split("/").pop() ?? p,
      dirname: (p) => p.slice(0, Math.max(1, p.lastIndexOf("/"))),
      exists: async (p) => fs.has(p) || [...fs.keys()].some((k) => k.startsWith(p + "/")),
      read: async (p) => fs.get(p) ?? null,
      readText: async (p) => (fs.has(p) ? dec(fs.get(p)!) : null),
      write: async (p, d) => { fs.set(p, typeof d === "string" ? enc(d) : d); urls.delete(p); return true; },
      mkdirs: async () => true,
      list: async (p) => [...fs.keys()].filter((k) => k.startsWith(p + "/")).map((k) => k.slice(p.length + 1)),
      remove: async (p) => fs.delete(p),
      size: async (p) => fs.get(p)?.length ?? null,
      pickOpen: async (types) => {
        if (types.includes("txt")) { fs.set("/Users/you/Desktop/script.txt", enc("Welcome back to the channel.\nToday we look at three ways to light a small room.")); return "/Users/you/Desktop/script.txt"; }
        fs.set("/Users/you/Desktop/my-voice.wav", toneWav(12)); return "/Users/you/Desktop/my-voice.wav";
      },
      pickSave: async (name) => "/Users/you/Desktop/" + name,
      pickFolder: async () => "/Users/you/Projects/Voice-over",
    },
    http: { request: http },
    secrets: {
      get: async (n) => secrets.get(n) ?? "",
      set: async (n, v) => { secrets.set(n, v); return true; },
    },
    shell: {
      openUrl: async (u) => { console.log("[preview] open", u); return true; },
      openFolder: async (p) => { console.log("[preview] show folder", p); return true; },
      openSoundSettings: async () => { console.log("[preview] sound settings"); return true; },
    },
    player: createMediaPlayer(media, urlFor),
    samples: createMediaPlayer(o.samplesMedia ?? media, urlFor),
    timeline: {
      projectName: async () => o.project ?? "Kitchen Tour",
      projectId: async () => "preview-project",
      hasSequence: async () => o.sequence !== false,
      binName: async () => "Higgs VoiceOver",
      importToBin: async (paths) => { paths.forEach((p) => bin.add(p)); return { ok: true }; },
      audioTracks: async () => (o.sequence === false ? [] : tracks.map((t) => t.name)),
      place: async (takes: { path: string; seconds: number }[], target: TrackTarget) => {
        let i = target.index ?? tracks.findIndex((t) => t.name === target.name);
        if (i === -1) { tracks.push({ name: target.name, spans: [] }); i = tracks.length - 1; }
        const track = tracks[i];
        if (!track) return { ok: false, placed: 0, starts: [], ends: [], pushed: false, fps: 25, error: `This sequence has no A${i + 1} track. Choose another track in Settings.` };
        const playhead = 12;
        let at = Math.max(playhead, ...track.spans.map((s) => s.end));
        const pushed = at > playhead;
        const starts: number[] = [], ends: number[] = [];
        for (const t of takes) { starts.push(at); ends.push(at + t.seconds); track.spans.push({ start: at, end: at + t.seconds }); at += t.seconds; }
        const r: PlaceResult = { ok: true, placed: takes.length, starts, ends, pushed, fps: 25, track: `A${i + 1}` };
        placed.push(r);
        return r;
      },
      ...(o.cep ? { addCaptions: async (path: string) => { bin.add(path); return { ok: true }; } } : {}),
    },
    ...(o.cep ? { recorder: mockRecorder(), richText: true } : {}),
    info: {
      appName: o.cep ? "Premiere Pro (preview, CEP)" : "Premiere Pro (preview, UXP)",
      appVersion: "26.5",
      pluginVersion: "0.1.0",
      os: "macos",
      theme: () => theme,
      onTheme: (cb) => themeListeners.push(cb),
    },
    // For the preview's own controls.
    setTheme(t: string) { theme = t; themeListeners.forEach((cb) => cb(t)); },
  } as Host & { placed: PlaceResult[]; fs: Map<string, Uint8Array>; setTheme(t: string): void };
}

export type { Take };
