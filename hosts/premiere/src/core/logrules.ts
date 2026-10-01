// The log's rules: how a line looks, how user content is marked, and how a
// copy is redacted before it ever leaves the machine. Port of the pure parts
// of hosts/resolve/src/higgs/log.lua; the file itself belongs to the host.
//
// Every line: time with milliseconds, level, category, message, then
// key=value fields. Levels: info · warn · error · ui (a user action) ·
// metric (a measured outcome).
//
// User content is wrapped with q() and home paths with pathSafe(), so a copy
// can be redacted mechanically (redact) before it ever leaves the machine.
// The API key is never written.
//
// Each launch writes logs/higgs-vo-<date>-<time>.log; the ten newest are kept.

export type Level = "info" | "warn" | "error" | "ui" | "metric";
export type Fields = Record<string, unknown>;

export const KEEP = 10;

/** User content (project, voice and file names). Marked so redact() can
 * remove it; never pass the text a user is voicing — log its length. */
const OPEN = "‹", CLOSE = "›";

function stripMarks(s: string): string {
  return s.split(OPEN).join("").split(CLOSE).join("");
}

export function q(s: unknown): string {
  return OPEN + stripMarks(String(s ?? "")) + CLOSE;
}

/** A path with the home folder written as ~. */
export function pathSafe(p: unknown, home: string | null | undefined): string {
  let s = String(p ?? "");
  if (home && s.startsWith(home)) s = "~" + s.slice(home.length);
  return s;
}

/** A number the way Lua's tostring() writes it (%.14g). */
export function luaNumber(v: number): string {
  if (Number.isNaN(v)) return "nan";
  if (v === Infinity) return "inf";
  if (v === -Infinity) return "-inf";
  if (v === 0) return "0";
  const sign = v < 0 ? "-" : "";
  const a = Math.abs(v);
  const [mant, ex] = a.toExponential(13).split("e");
  const x = Number(ex);
  const trimZeros = (s: string) => (s.includes(".") ? s.replace(/0+$/, "").replace(/\.$/, "") : s);
  if (x < -4 || x >= 14) {
    return sign + trimZeros(mant) + "e" + (x < 0 ? "-" : "+") + String(Math.abs(x)).padStart(2, "0");
  }
  return sign + trimZeros(a.toFixed(13 - x));
}

/** key=value pairs in a stable order. Values with spaces are quoted. */
export function fields(t: Fields | null | undefined): string {
  if (!t || typeof t !== "object") return "";
  const out: string[] = [];
  for (const k of Object.keys(t).sort()) {
    const raw = t[k];
    let v: string;
    if (typeof raw === "number") {
      v = raw !== Math.floor(raw) && Number.isFinite(raw)
        ? raw.toFixed(3).replace(/0+$/, "").replace(/\.$/, "")
        : luaNumber(raw);
    } else {
      v = String(raw);
    }
    if (/[ \t\n\v\f\r=]/.test(v) && !v.startsWith(OPEN)) v = '"' + v.replace(/"/g, "'") + '"';
    out.push(k + "=" + v);
  }
  return out.join(" ");
}

/** A message with its optional fields, as info()/warn()/error()/ui() write it:
 * entry("placed", { clips: 2 }) → "placed  clips=2". */
export function entry(message: string, t?: Fields | null): string {
  return t ? message + "  " + fields(t) : message;
}

/** Wall-clock time as the log stamps it: HH:MM:SS.mmm, local time.
 * `seconds` is Unix time with a fraction. */
export function formatStamp(seconds: number): string {
  const d = new Date(Math.floor(seconds) * 1000);
  const p2 = (n: number) => String(n).padStart(2, "0");
  const ms = Math.floor((seconds - Math.floor(seconds)) * 1000);
  return `${p2(d.getHours())}:${p2(d.getMinutes())}:${p2(d.getSeconds())}.${String(ms).padStart(3, "0")}`;
}

/** One line of the file, without its newline: stamp, level padded to six,
 * message on one line. */
export function formatLine(stamp: string, level: string, message: unknown): string {
  return stamp + " " + level.padEnd(6) + " " + String(message).replace(/[\r\n]+/g, " ");
}

/** The first line of a launch's file. */
export function headerLine(date: Date, session: string): string {
  const p2 = (n: number) => String(n).padStart(2, "0");
  const when = `${date.getFullYear()}-${p2(date.getMonth() + 1)}-${p2(date.getDate())} ` +
    `${p2(date.getHours())}:${p2(date.getMinutes())}:${p2(date.getSeconds())}`;
  return `# Higgs VoiceOver log · ${when} · session ${session}`;
}

/** This launch's file name: higgs-vo-<YYYYMMDD>-<HHMMSS>.log, local time. */
export function logFileName(date: Date): string {
  const p2 = (n: number) => String(n).padStart(2, "0");
  return `higgs-vo-${date.getFullYear()}${p2(date.getMonth() + 1)}${p2(date.getDate())}-` +
    `${p2(date.getHours())}${p2(date.getMinutes())}${p2(date.getSeconds())}.log`;
}

export function isLogFileName(name: string): boolean {
  return /^higgs-vo-\d+-\d+\.log$/.test(name);
}

/** Which of the existing log files to delete before a new launch writes
 * its own, so `keep` remain: the oldest by name. */
export function logsToRemove(names: string[], keep = KEEP): string[] {
  const logs = names.filter(isLogFileName).sort();
  return logs.slice(0, Math.max(0, logs.length - (keep - 1)));
}

/** A random id per launch, so a report can group lines. */
export function newSession(random: () => number = Math.random): string {
  return Math.floor(random() * 0x80000000).toString(16).padStart(8, "0");
}

/** Counters for the session summary and the report bundle.
 * counts[name] = number of times; sums[name.field] = running total. */
export interface Totals {
  counts: Record<string, number>;
  sums: Record<string, number>;
}

/** A measured outcome: folded into the session totals (every numeric field
 * is summed under name.field) and returned as the message to write at
 * level "metric". */
export function metric(totals: Totals, name: string, t?: Fields | null): string {
  const f = t ?? {};
  totals.counts[name] = (totals.counts[name] ?? 0) + 1;
  for (const [k, v] of Object.entries(f)) {
    if (typeof v === "number") {
      const key = name + "." + k;
      totals.sums[key] = (totals.sums[key] ?? 0) + v;
    }
  }
  return name + "  " + fields(f);
}

/** Count warnings and errors as write() does. */
export function countLevel(totals: Totals, level: string): void {
  if (level === "warn") totals.counts["log.warn"] = (totals.counts["log.warn"] ?? 0) + 1;
  if (level === "error") totals.counts["log.error"] = (totals.counts["log.error"] ?? 0) + 1;
}

/** One line at exit: how long the session ran and what it did. Returns the
 * fields and the message to write at level "metric". */
export function summary(totals: Totals, seconds: number): { fields: Fields; message: string } {
  const t: Fields = { seconds: Math.floor(seconds) };
  for (const [k, v] of Object.entries(totals.counts)) t[k] = v;
  for (const [k, v] of Object.entries(totals.sums)) t[k] = v;
  return { fields: t, message: "session  " + fields(t) };
}

/** A copy of a log with user content removed: ‹…› becomes ‹›, and any
 * home path that slipped through unwrapped loses its user name. */
export function redact(text: unknown): string {
  let s = String(text ?? "");
  const parts: string[] = [];
  let i = 0;
  for (;;) {
    const a = s.indexOf(OPEN, i);
    if (a < 0) { parts.push(s.slice(i)); break; }
    const c = s.indexOf(CLOSE, a + OPEN.length);
    if (c < 0) { parts.push(s.slice(i)); break; }
    parts.push(s.slice(i, a + OPEN.length) + CLOSE);
    i = c + CLOSE.length;
  }
  s = parts.join("");
  // Messages shown to the user quote names in curly quotes.
  s = s.replace(/“[\s\S]*?”/g, "“”");
  s = s.replace(/\/Users\/[^/ \t\n\v\f\r]+/g, "/Users/~").replace(/\/home\/[^/ \t\n\v\f\r]+/g, "/home/~");
  return s;
}

/** This session's totals and its log, redacted: what a problem report
 * would carry. Nothing sends it. */
export function bundle(opts: { session: string; version: string; platform: string; totals: Totals; log: string }) {
  return {
    session: opts.session,
    version: opts.version,
    platform: opts.platform,
    counts: opts.totals.counts,
    sums: opts.totals.sums,
    log: redact(opts.log),
  };
}
