// What the panel needs from the world outside it. Premiere provides it in
// ./uxp/; the browser preview and the tests provide stand-ins with the same
// shape, so everything above this line runs without Premiere.

export interface Files {
  /** The plugin's own data folder (settings, logs, drafts), as a native path. */
  readonly dataDir: string;
  /** The user's home folder; logs write it as ~. */
  readonly home: string;
  /** Where clips go unless Settings says otherwise: ~/Movies (macOS) or ~/Videos (Windows). */
  readonly mediaDir: string;
  readonly sep: string;
  join(...parts: string[]): string;
  basename(path: string): string;
  dirname(path: string): string;
  exists(path: string): Promise<boolean>;
  read(path: string): Promise<Uint8Array | null>;
  readText(path: string): Promise<string | null>;
  write(path: string, data: Uint8Array | string): Promise<boolean>;
  mkdirs(path: string): Promise<boolean>;
  list(path: string): Promise<string[]>;
  remove(path: string): Promise<boolean>;
  size(path: string): Promise<number | null>;
  /** File pickers; null when the user cancels. */
  pickOpen(types: string[]): Promise<string | null>;
  pickSave(suggestedName: string, types: string[]): Promise<string | null>;
  pickFolder(): Promise<string | null>;
}

export interface HttpRequest {
  method: "GET" | "POST" | "DELETE";
  url: string;
  headers?: Record<string, string>;
  body?: string;
  timeoutMs?: number;
}

export interface HttpResponse {
  /** 0 when nothing came back: offline, DNS, timeout (curl's 000). */
  status: number;
  bytes: Uint8Array;
  text: string;
  /** Why there is no status, in the transport's words (for the log only). */
  error?: string;
}

export interface Http {
  request(req: HttpRequest, signal?: AbortSignal): Promise<HttpResponse>;
}

export interface Secrets {
  get(name: string): Promise<string>;
  set(name: string, value: string): Promise<boolean>;
}

export interface Shell {
  openUrl(url: string): Promise<boolean>;
  openFolder(path: string): Promise<boolean>;
}

export type PlayerState = "empty" | "stopped" | "playing" | "paused";

export interface Player {
  readonly state: PlayerState;
  /** Seconds into the loaded file. */
  readonly position: number;
  readonly duration: number;
  load(path: string, seconds: number): void;
  play(): void;
  pause(): void;
  stop(): void;
  seek(seconds: number): void;
  /** Called on every position change, end and state change. */
  onChange(cb: () => void): void;
}

export interface Take {
  path: string;
  seconds: number;
  text: string;
  words?: unknown;
  pause: number;
}

export interface PlaceResult {
  ok: boolean;
  placed: number;
  /** Sequence time of each placed clip, as Premiere reports it, in seconds. */
  starts: number[];
  ends: number[];
  /** The first clip went after one already at the playhead. */
  pushed: boolean;
  fps: number;
  error?: string;
}

export interface Timeline {
  /** "" when no project is open. */
  projectName(): Promise<string>;
  /** Stable id of the open project, for its draft; "" without one. */
  projectId(): Promise<string>;
  hasSequence(): Promise<boolean>;
  /** The bin clips go into in this project: an existing one, else the one that will be made. */
  binName(): Promise<string>;
  /** Import files into the bin (made if missing); files already there are not imported twice. */
  importToBin(paths: string[]): Promise<{ ok: boolean; error?: string }>;
  /** Place the takes back to back on the named audio track at the playhead, or after what is there. */
  place(paths: { path: string; seconds: number }[], trackName: string): Promise<PlaceResult>;
  /**
   * Native captions from an .srt, its time zero at `atSeconds` in the
   * sequence. Only where the host can (CEP: ExtendScript createCaptionTrack);
   * without it subtitles go to the bin for the user to drag in.
   */
  addCaptions?(srtPath: string, atSeconds: number): Promise<{ ok: boolean; error?: string }>;
}

/**
 * The microphone, where the host gives a panel one (CEP's Chromium; not
 * UXP). Captures the system's default input as 24 kHz mono 16-bit PCM, the
 * format core/wav.ts and core/recorder.ts work in.
 */
export interface Recorder {
  /** The input that will be used, by name ("" if unknown). */
  device(): Promise<string>;
  /** Open the input; capture starts at `begin()`, so a count-in records nothing. */
  open(): Promise<{ ok: boolean; error?: string }>;
  begin(): void;
  /** Loudest sample since the last call, 0–1. */
  level(): number;
  /** Seconds captured so far. */
  seconds(): number;
  /** Stop and hand back the PCM (null if nothing was captured). Closes the input. */
  stop(): Promise<Uint8Array | null>;
  /** Stop and drop everything. */
  cancel(): void;
}

export interface HostInfo {
  readonly appName: string;
  readonly appVersion: string;
  readonly pluginVersion: string;
  readonly os: "macos" | "windows";
  theme(): string;
  onTheme(cb: (theme: string) => void): void;
}

export interface Host {
  files: Files;
  http: Http;
  secrets: Secrets;
  shell: Shell;
  player: Player;
  timeline: Timeline;
  info: HostInfo;
  recorder?: Recorder;
  /** The panel is Chromium: tags can be coloured inside the text box. */
  richText?: boolean;
}
