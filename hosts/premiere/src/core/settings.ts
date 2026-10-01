// Settings: defaults, schema migrations, the stored API key and the voice
// library. Port of the pure parts of hosts/resolve/src/higgs/config.lua;
// where the file lives and how it is read and written belong to the host.

import { b64Encode, utf8Decode, utf8Encode } from "./base64.ts";

/** Bump when a released schema changes so migrate() can fix older files. */
export const SCHEMA = 5;

/** The product's name, and the folder name for clips under the user's video
 * folder. */
export const APP_NAME = "Higgs VoiceOver";

export interface ClipNameParts {
  words?: boolean;
  date?: boolean;
  time?: boolean;
  take?: boolean;
}

export interface Voice {
  id: string;
  name: string;
  created: number;
}

export interface Settings {
  schema: number;
  api_key_b64: string;
  default_voice: string;
  output_format: string;
  auto_preview: boolean;
  auto_place: boolean;
  auto_subtitles: boolean;
  manual_subtitles: boolean;
  subtitle_split: string;
  pause_enabled: boolean;
  pause_ms: number;
  clip_name: ClipNameParts;
  output_dir: string;
  vo_track_name: string;
  replace_mode: string;
  gap_seconds: number;
  check_updates: boolean;
  last_update_check: number;
  update_state: string;
  voices: Voice[];
  recent_files: string[];
  [key: string]: unknown;
}

export type Config = Settings;

/** The two folders migrations compare against: the old application-support
 * takes folder, and today's default under the user's video folder. */
export interface SettingsDirs {
  takesDir: string;
  defaultOutputDir: string;
}

export const DEFAULTS: Readonly<Settings> = Object.freeze({
  schema: SCHEMA,
  api_key_b64: "",
  default_voice: "nora",
  output_format: "wav",
  // Silence appended to every clip so consecutive lines breathe (wav only).
  auto_preview: true,        // play the takes as soon as a generation finishes
  auto_place: true,          // put every clip of a finished run on the timeline (0.2.0: on)
  // Subtitles go on the timeline with the clips, timed to Boson's word
  // timings: "short" phrases of one line, or one "sentence" per subtitle.
  auto_subtitles: false,     // with automatic placing (box beside Generate)
  manual_subtitles: false,   // with the Place buttons (box in the audio preview)
  subtitle_split: "short",
  pause_enabled: true,
  pause_ms: 400,
  // Clip and file names: the first four words, plus any of these.
  clip_name: Object.freeze({ words: true, date: false, time: false, take: false }),
  output_dir: "",            // resolved to the default output folder on first load
  vo_track_name: "Higgs VO",
  // "adopt" re-times the clip to the new take; "keep" holds the original
  // boundaries and truncates. Defaults to adopt for script-first work; SRT-timed
  // segments override per segment.
  replace_mode: "adopt",
  gap_seconds: 0.35,         // silence inserted between sequential segments
  check_updates: true,       // look for a new release once a day at launch
  last_update_check: 0,
  update_state: "",          // "current" / "available" after the last successful check
  voices: Object.freeze([]) as unknown as Voice[],   // cloned voice library
  recent_files: Object.freeze([]) as unknown as string[],
});

type Loose = Record<string, unknown>;

/** Fill what a stored config lacks from DEFAULTS. Table defaults are copied
 * the way the Lua copies them — list items only — so a missing `clip_name`
 * becomes {} rather than the record above; readers treat a missing `words`
 * as on (`clip_name.words !== false`), which is the same naming. */
export function applyDefaults(cfg: Loose, defaultOutputDir: string): Settings {
  for (const [k, v] of Object.entries(DEFAULTS)) {
    if (cfg[k] === undefined || cfg[k] === null) {
      cfg[k] = v && typeof v === "object" ? (Array.isArray(v) ? [...v] : {}) : v;
    }
  }
  if (cfg.output_dir === "") cfg.output_dir = defaultOutputDir;
  return cfg as Settings;
}

/** Upgrade a config written by an older release.
 * Unknown (newer) schemas are left alone: a user who downgrades keeps their
 * settings rather than having them silently rewritten. */
export function migrate(cfg: Loose, dirs: SettingsDirs): Loose {
  if (cfg.schema === undefined || cfg.schema === null) cfg.schema = 0;
  const schema = cfg.schema as number;
  // 2 dropped the clip pause default from 400 ms to 240; 4 put it back.
  // A config on either default ends on 400; a value the user chose is kept.
  if (schema < 4 && cfg.pause_ms === 240) cfg.pause_ms = 400;
  // 3: takes moved out of application support and into the user's video
  // folder, one subfolder per project. A config still on the old default
  // follows; a folder the user picked is left exactly where they put it.
  if (schema < 3 && (cfg.output_dir === dirs.takesDir || cfg.output_dir === "")) {
    cfg.output_dir = dirs.defaultOutputDir;
  }
  // 5 turned "Place on timeline" on by default; a config still on the old
  // default (off) follows.
  if (schema < 5 && cfg.auto_place === false) cfg.auto_place = true;
  if (schema < SCHEMA) cfg.schema = SCHEMA;
  return cfg;
}

/** Settings from a stored config, already parsed from its JSON: migrated,
 * then completed from DEFAULTS. Anything that is not a record (an unreadable
 * file the caller kept aside as config.json.bad, or no file at all) gives the
 * defaults. Without `dirs`, `output_dir` may come back "" for the caller to
 * resolve to the default folder. */
export function load(parsed: unknown, dirs: SettingsDirs = { takesDir: "", defaultOutputDir: "" }): Settings {
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return applyDefaults({}, dirs.defaultOutputDir);
  return applyDefaults(migrate(parsed as Loose, dirs), dirs.defaultOutputDir);
}

// ------------------------------------------------------------- credentials

const B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/** The stored key's decoder, stricter than the audio one: a group whose first
 * two characters are not base64 makes the whole key unreadable (null). */
export function b64Decode(s: unknown): Uint8Array | null {
  const clean = String(s).replace(/[^A-Za-z0-9+/=]/g, "");
  const out: number[] = [];
  for (let i = 0; i + 3 < clean.length; i += 4) {
    const c1 = B64_CHARS.indexOf(clean[i]), c2 = B64_CHARS.indexOf(clean[i + 1]);
    const ch3 = clean[i + 2], ch4 = clean[i + 3];
    if (c1 < 0 || c2 < 0) return null;
    const c3 = B64_CHARS.indexOf(ch3), c4 = B64_CHARS.indexOf(ch4);
    const n = c1 * 262144 + c2 * 4096 + Math.max(0, c3) * 64 + Math.max(0, c4);
    out.push(Math.floor(n / 65536) % 256);
    if (ch3 !== "=") out.push(Math.floor(n / 256) % 256);
    if (ch4 !== "=") out.push(n % 256);
  }
  return Uint8Array.from(out);
}

/** The API key is base64-encoded in the settings.
 * That is obfuscation, not encryption — anyone with access to this user account
 * can read it. Say this plainly in the UI rather than implying it is secure. */
export function getApiKey(cfg: { api_key_b64?: string | null }): string {
  const b64 = cfg.api_key_b64 || "";
  if (b64 === "") return "";
  const decoded = b64Decode(b64);
  return decoded ? utf8Decode(decoded) : "";
}

export function setApiKey(cfg: { api_key_b64?: string }, key: string | null | undefined): void {
  cfg.api_key_b64 = key ? b64Encode(utf8Encode(key)) : "";
}

// ----------------------------------------------------------- voice library

/** Add a cloned voice, or rename it if its id is already there. `now` is
 * the creation time in Unix seconds. */
export function addVoice(cfg: { voices: Voice[] }, id: string, name: string, now = Math.floor(Date.now() / 1000)): Voice {
  for (const v of cfg.voices) {
    if (v.id === id) {
      v.name = name;
      return v;
    }
  }
  const entry: Voice = { id, name, created: now };
  cfg.voices.push(entry);
  return entry;
}

export function removeVoice(cfg: { voices: Voice[] }, id: string): boolean {
  const i = cfg.voices.findIndex((v) => v.id === id);
  if (i < 0) return false;
  cfg.voices.splice(i, 1);
  return true;
}

export function findVoice(cfg: { voices: Voice[] }, id: string): Voice | null {
  return cfg.voices.find((v) => v.id === id) ?? null;
}
