// The CEP build's files, network, key, links and host facts, through the
// panel's Node.js (manifest: --enable-nodejs --mixed-context) and CEP's own
// window objects.

import type { Files, Http, HostInfo, Secrets, Shell } from "../host.ts";

const fs = require("fs") as typeof import("fs") & { promises: typeof import("node:fs/promises") };
const nodePath = require("path") as typeof import("node:path");
const os = require("os") as typeof import("node:os");
const https = require("https") as typeof import("node:https");
const childProcess = require("child_process") as typeof import("node:child_process");

const windows = process.platform === "win32";

/**
 * Settings, key, logs and drafts: a folder of the Premiere build's own,
 * beside the Resolve build's "HiggsVO", so either can be reset or removed
 * without touching the other. Only the user can read it (the key is in it).
 */
const appSupport = windows ? (process.env.APPDATA ?? nodePath.join(os.homedir(), "AppData", "Roaming"))
                           : nodePath.join(os.homedir(), "Library", "Application Support");
const DATA_DIR = nodePath.join(appSupport, "HiggsVO-Premiere");
// 0.1.0 test builds kept it inside the Resolve build's folder; move it once.
const OLD_DATA_DIR = nodePath.join(appSupport, "HiggsVO", "Premiere");

function dataDir(): string {
  return DATA_DIR;
}

/** Move an earlier data folder into place and make the folder private. Run once at start. */
export function prepareDataDir(): void {
  try {
    if (!fs.existsSync(DATA_DIR) && fs.existsSync(OLD_DATA_DIR)) fs.renameSync(OLD_DATA_DIR, DATA_DIR);
    fs.mkdirSync(DATA_DIR, { recursive: true });
    if (!windows) fs.chmodSync(DATA_DIR, 0o700);
  } catch { /* the folder is made again on first write */ }
}

export function createFiles(): Files {
  const fsp = fs.promises;
  const picked = (r: { err: number; data: string | string[] } | undefined) => {
    if (!r || r.err !== 0) return null;
    const p = Array.isArray(r.data) ? r.data[0] : r.data;
    return p ? String(p) : null;
  };
  return {
    dataDir: dataDir(),
    home: os.homedir(),
    mediaDir: nodePath.join(os.homedir(), windows ? "Videos" : "Movies"),
    sep: nodePath.sep,
    join: (...parts) => nodePath.join(...parts.filter((p) => p !== "")),
    basename: (p) => nodePath.basename(p),
    dirname: (p) => nodePath.dirname(p),
    exists: async (p) => fs.existsSync(p),
    async read(p) { try { return new Uint8Array(await fsp.readFile(p)); } catch { return null; } },
    async readText(p) { try { return await fsp.readFile(p, "utf8"); } catch { return null; } },
    async write(p, data) {
      try {
        await fsp.mkdir(nodePath.dirname(p), { recursive: true });
        await fsp.writeFile(p, data);
        return true;
      } catch { return false; }
    },
    async mkdirs(p) { try { await fsp.mkdir(p, { recursive: true }); return true; } catch { return false; } },
    async list(p) { try { return await fsp.readdir(p); } catch { return []; } },
    async remove(p) { try { await fsp.unlink(p); return true; } catch { return false; } },
    async size(p) { try { return (await fsp.stat(p)).size; } catch { return null; } },
    async pickOpen(types) { return picked(window.cep?.fs.showOpenDialogEx(false, false, "Choose a file", undefined, types)); },
    async pickSave(name, types) { return picked(window.cep?.fs.showSaveDialogEx("Save as", undefined, types, name)); },
    async pickFolder() { return picked(window.cep?.fs.showOpenDialogEx(false, true, "Choose a folder")); },
  };
}

/**
 * HTTPS through Node rather than fetch: a panel's page has a file: origin,
 * and Boson's API sends no CORS headers for it. Status 0 means nothing came back.
 */
export const http: Http = {
  request(req, signal) {
    return new Promise((resolve) => {
      const url = new URL(req.url);
      const done = (status: number, bytes: Uint8Array, error?: string) =>
        resolve({ status, bytes, text: new TextDecoder().decode(bytes), error });
      const r = https.request({
        method: req.method, hostname: url.hostname, path: url.pathname + url.search,
        headers: { ...(req.headers ?? {}), ...(req.body ? { "Content-Length": String(Buffer.byteLength(req.body)) } : {}) },
        timeout: req.timeoutMs ?? 120_000,
      }, (res) => {
        // GitHub serves release files through a redirect; nothing with a key follows one.
        const loc = res.headers.location;
        if (loc && res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && !req.headers?.Authorization) {
          res.resume();
          void http.request({ ...req, url: new URL(loc, req.url).toString() }, signal).then(resolve);
          return;
        }
        const parts: Buffer[] = [];
        res.on("data", (c: Buffer) => parts.push(c));
        res.on("end", () => done(res.statusCode ?? 0, new Uint8Array(Buffer.concat(parts))));
        res.on("error", (e) => done(0, new Uint8Array(0), String(e)));
      });
      r.on("timeout", () => r.destroy(new Error("timed out")));
      r.on("error", (e) => done(0, new Uint8Array(0), signal?.aborted ? "cancelled" : String(e)));
      signal?.addEventListener("abort", () => r.destroy(new Error("cancelled")));
      if (req.body) r.write(req.body);
      r.end();
    });
  },
};

/**
 * The key in a file only the user can read, as the Resolve build keeps it:
 * CEP has no keychain access of its own.
 */
export const secrets: Secrets = {
  async get(name) {
    try { return fs.readFileSync(nodePath.join(dataDir(), name), "utf8").trim(); } catch { return ""; }
  },
  async set(name, value) {
    try {
      fs.mkdirSync(dataDir(), { recursive: true });
      const p = nodePath.join(dataDir(), name);
      if (value === "") { if (fs.existsSync(p)) fs.unlinkSync(p); return true; }
      fs.writeFileSync(p, value, { mode: 0o600 });
      fs.chmodSync(p, 0o600);
      return true;
    } catch { return false; }
  },
};

export const shell: Shell = {
  async openUrl(url) { return window.cep?.util.openURLInDefaultBrowser(url) === 0; },
  // macOS Sound settings on the Input tab; Windows Sound settings.
  async openSoundSettings() {
    try {
      const target = windows ? "ms-settings:sound" : "x-apple.systempreferences:com.apple.Sound-Settings.extension?input";
      childProcess.spawn(windows ? "explorer" : "open", [target], { detached: true, stdio: "ignore" }).unref();
      return true;
    } catch { return false; }
  },
  async openFolder(p) {
    try {
      childProcess.spawn(windows ? "explorer" : "open", [p], { detached: true, stdio: "ignore" }).unref();
      return true;
    } catch { return false; }
  },
};

interface HostEnv { appVersion?: string; appSkinInfo?: { panelBackgroundColor?: { color?: { red: number; green: number; blue: number } } } }

/** Premiere's brightness as a theme name, from the panel background CEP reports. */
export function themeFromBackground(rgb: { red: number; green: number; blue: number } | undefined): string {
  if (!rgb) return "darkest";
  const lum = (0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue) / 255;
  return lum > 0.5 ? "light" : lum > 0.13 ? "dark" : "darkest";
}

export function hostInfo(pluginVersion: string): HostInfo {
  const env = (): HostEnv => { try { return JSON.parse(window.__adobe_cep__?.getHostEnvironment() ?? "{}"); } catch { return {}; } };
  const theme = () => themeFromBackground(env().appSkinInfo?.panelBackgroundColor?.color);
  const listeners: ((t: string) => void)[] = [];
  window.__adobe_cep__?.addEventListener("com.adobe.csxs.events.ThemeColorChanged", () => listeners.forEach((cb) => cb(theme())));
  return {
    // The macOS installer first; the .zxp (UPIA or an extension manager) everywhere.
    packages: windows ? ["zxp"] : ["pkg", "zxp"],
    appName: "Premiere Pro",
    appVersion: env().appVersion ?? "",
    pluginVersion,
    os: windows ? "windows" : "macos",
    theme,
    onTheme: (cb) => { listeners.push(cb); },
  };
}
