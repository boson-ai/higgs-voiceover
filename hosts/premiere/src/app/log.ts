// One plain-text log per session in the plugin's data folder — the same
// format as the Resolve build's, so one reader serves both. User content
// (names, paths) is wrapped by `q` so a copy for a report can be redacted;
// the text being voiced is never logged, only its length.

import type { Files } from "../host/host.ts";
import { fields, q as quote } from "../core/logrules.ts";

const KEEP = 10;

export interface Log {
  readonly path: string;
  info(message: string, t?: Record<string, unknown>): void;
  warn(message: string, t?: Record<string, unknown>): void;
  error(message: string, t?: Record<string, unknown>): void;
  ui(message: string, t?: Record<string, unknown>): void;
  metric(name: string, t?: Record<string, unknown>): void;
  q(s: unknown): string;
  pathSafe(p: string): string;
  summary(): void;
}

const pad = (n: number, w = 2) => String(n).padStart(w, "0");

export async function startLog(files: Files, version: string): Promise<Log> {
  const home = files.home;
  const dir = files.join(files.dataDir, "logs");
  await files.mkdirs(dir);
  const now = new Date();
  const name = `higgs-vo-${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}.log`;
  const path = files.join(dir, name);
  const old = (await files.list(dir)).filter((n) => /^higgs-vo-.*\.log$/.test(n)).sort();
  for (const n of old.slice(0, Math.max(0, old.length - (KEEP - 1)))) await files.remove(files.join(dir, n));

  const session = Math.floor(Math.random() * 0x7fffffff).toString(16).padStart(8, "0");
  const started = Date.now();
  const counts: Record<string, number> = {};
  const sums: Record<string, number> = {};

  // Writes are queued so lines land in order without the caller waiting.
  let text = `# Higgs VoiceOver ${version} log · ${now.toISOString().slice(0, 19).replace("T", " ")} · session ${session}\n`;
  let pending: Promise<unknown> = files.write(path, text);
  const write = (level: string, message: string) => {
    if (level === "warn" || level === "error") counts["log." + level] = (counts["log." + level] ?? 0) + 1;
    const t = new Date();
    const line = `${pad(t.getHours())}:${pad(t.getMinutes())}:${pad(t.getSeconds())}.${pad(t.getMilliseconds(), 3)} ${level.padEnd(6)} ${message.replace(/[\r\n]+/g, " ")}\n`;
    text += line;
    pending = pending.then(() => files.write(path, text));
    console.log(line.trimEnd());
  };
  // An absent value is left out, as Lua's nil is.
  const defined = (t: Record<string, unknown>) => Object.fromEntries(Object.entries(t).filter(([, v]) => v !== undefined && v !== null));
  const withFields = (m: string, t?: Record<string, unknown>) => (t ? `${m}  ${fields(defined(t))}` : m);

  return {
    path,
    info: (m, t) => write("info", withFields(m, t)),
    warn: (m, t) => write("warn", withFields(m, t)),
    error: (m, t) => write("error", withFields(m, t)),
    ui: (m, t) => write("ui", withFields(m, t)),
    metric(name, t = {}) {
      counts[name] = (counts[name] ?? 0) + 1;
      for (const [k, v] of Object.entries(t)) if (typeof v === "number") sums[`${name}.${k}`] = (sums[`${name}.${k}`] ?? 0) + v;
      write("metric", `${name}  ${fields(defined(t))}`);
    },
    q: quote,
    // Only the home folder itself: /Users/alexander is not under /Users/alex.
    pathSafe: (p) => (home && (p === home || p.startsWith(home + "/") || p.startsWith(home + "\\")) ? "~" + p.slice(home.length) : p),
    summary() {
      write("metric", `session  ${fields({ seconds: Math.floor((Date.now() - started) / 1000), ...counts, ...sums })}`);
    },
  };
}
