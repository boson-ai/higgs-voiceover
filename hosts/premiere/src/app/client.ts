// Boson's Higgs TTS 3 over fetch. Every rule — request shapes, error
// wording, what may be retried — is core/boson.ts, shared with the Resolve
// build; this file only moves the bytes and waits between retries.

import type { Http } from "../host/host.ts";
import type { Log } from "./log.ts";
import * as Boson from "../core/boson.ts";

export interface SpeechResult { ok: boolean; code?: string; audio?: Uint8Array; words?: Boson.Word[]; error?: string }

const wait = (ms: number, signal?: AbortSignal) => new Promise<void>((resolve) => {
  const t = setTimeout(resolve, ms);
  signal?.addEventListener("abort", () => { clearTimeout(t); resolve(); });
});

export class Client {
  private readonly http: Http;
  private readonly key: () => string;
  private readonly version: string;
  private readonly log: Log;
  private readonly sleep: (ms: number, signal?: AbortSignal) => Promise<void>;

  constructor(http: Http, key: () => string, version: string, log: Log, sleep = wait) {
    this.http = http;
    this.key = key;
    this.version = version;
    this.log = log;
    this.sleep = sleep;
  }

  /** One request, retried after RETRY_DELAYS while Boson says "too many requests". */
  async send(req: Boson.ApiRequest, key = this.key(), signal?: AbortSignal): Promise<Boson.ApiResult> {
    const missing = Boson.checkKey(key);
    if (missing) return missing;
    const { headers } = Boson.transportOptions(key, { hasBody: !!req.body, version: this.version });
    for (let retries = 0; ; retries++) {
      const t0 = Date.now();
      const r = await this.http.request({
        method: req.method, url: req.url, headers,
        body: req.body ? JSON.stringify(req.body) : undefined,
        timeoutMs: req.expect === "json" ? 30_000 : 180_000,
      }, signal);
      if (signal?.aborted) return { ok: false, code: "cancelled", error: "Stopped." };
      const res = Boson.interpret(r.status ? String(r.status) : "", r.bytes, r.error ?? "", req.expect);
      this.log.metric(Boson.apiMetricName(req.label), {
        ok: res.ok ? 1 : 0, code: res.code || "none", ms: Date.now() - t0, bytes: r.bytes.length, ...(req.meta ?? {}),
        ...(res.words ? { words: res.words.length } : {}),
      });
      if (!Boson.shouldRetry(res, retries)) return res;
      this.log.warn("rate limited, retrying", { after: Boson.RETRY_DELAYS[retries] });
      await this.sleep(Boson.RETRY_DELAYS[retries] * 1000, signal);
      if (signal?.aborted) return { ok: false, code: "cancelled", error: "Stopped." };
    }
  }

  async speech(spec: { text: string; voice: string; format: string; timestamps?: boolean }, signal?: AbortSignal): Promise<SpeechResult> {
    const built = Boson.speechRequest(spec);
    if (!("request" in built)) return built;
    return this.send(built.request, undefined, signal);
  }

  /** Does this key work? (Not necessarily the saved one.) */
  async test(key: string): Promise<{ ok: boolean; code?: string; error?: string }> {
    const res = await this.send(Boson.testRequest(), key);
    return Boson.testOutcome(res);
  }

  async createVoice(name: string, audio: Uint8Array, transcript: string): Promise<{ ok: boolean; id?: string; code?: string; error?: string }> {
    const built = Boson.createVoiceRequest({ name, audio, ref_text: transcript });
    if (!("request" in built)) return built;
    const res = await this.send(built.request);
    if (!res.ok) return res;
    const d = (res.data ?? {}) as { id?: unknown; voice_id?: unknown; voice?: unknown };
    const id = d.id ?? d.voice_id ?? d.voice;
    return typeof id === "string" && id ? { ok: true, id } : { ok: false, error: "Boson did not return a voice id." };
  }
}
