// Network, the key store, links and host facts — UXP's versions of what the
// Resolve build does with curl, a private file and `open`.

import type { Http, HostInfo, Secrets, Shell } from "../host.ts";

const uxp = require("uxp") as typeof import("uxp");
const os = require("os") as typeof import("os");

/** fetch with a timeout. Status 0 means nothing came back (offline, DNS, timeout). */
export const http: Http = {
  async request(req, signal) {
    const ctl = new AbortController();
    const onAbort = () => ctl.abort();
    signal?.addEventListener("abort", onAbort);
    const timer = setTimeout(() => ctl.abort(), req.timeoutMs ?? 120_000);
    try {
      const res = await fetch(req.url, { method: req.method, headers: req.headers, body: req.body, signal: ctl.signal });
      const bytes = new Uint8Array(await res.arrayBuffer()).slice();
      return { status: res.status, bytes, text: decodeUtf8Lossy(bytes) };
    } catch (e) {
      return { status: 0, bytes: new Uint8Array(0), text: "", error: signal?.aborted ? "cancelled" : String(e) };
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    }
  },
};

// UXP has no TextDecoder. Bodies worth reading as text (JSON, error pages)
// are UTF-8; a malformed byte becomes U+FFFD rather than an exception.
function decodeUtf8Lossy(b: Uint8Array): string {
  let out = "";
  for (let i = 0; i < b.length; ) {
    const c = b[i];
    let cp = 0xfffd, n = 1;
    if (c < 0x80) cp = c;
    else if (c >= 0xc2 && c < 0xe0 && i + 1 < b.length) { cp = ((c & 0x1f) << 6) | (b[i + 1] & 0x3f); n = 2; }
    else if (c >= 0xe0 && c < 0xf0 && i + 2 < b.length) { cp = ((c & 0x0f) << 12) | ((b[i + 1] & 0x3f) << 6) | (b[i + 2] & 0x3f); n = 3; }
    else if (c >= 0xf0 && c < 0xf5 && i + 3 < b.length) {
      cp = ((c & 0x07) << 18) | ((b[i + 1] & 0x3f) << 12) | ((b[i + 2] & 0x3f) << 6) | (b[i + 3] & 0x3f); n = 4;
    }
    out += String.fromCodePoint(cp);
    i += n;
  }
  return out;
}

/**
 * The API key lives in UXP's secure storage (encrypted per plugin). Adobe
 * says to treat it as a cache: if it is ever lost, onboarding asks again.
 */
export const secrets: Secrets = {
  async get(name) {
    try {
      const v = await uxp.storage.secureStorage.getItem(name);
      return v ? decodeUtf8Lossy(new Uint8Array(v)) : "";
    } catch { return ""; }
  },
  async set(name, value) {
    try {
      if (value === "") await uxp.storage.secureStorage.removeItem(name);
      else await uxp.storage.secureStorage.setItem(name, value);
      return true;
    } catch { return false; }
  },
};

// Premiere asks the user before opening anything; an empty string back
// means it went ahead.
export const shell: Shell = {
  async openUrl(url) {
    try { return (await uxp.shell.openExternal(url, "Opens a Higgs VoiceOver link in your browser.")) === ""; } catch { return false; }
  },
  async openFolder(path) {
    try { return (await uxp.shell.openPath(path, "Shows the Higgs VoiceOver folder.")) === ""; } catch { return false; }
  },
};

export function hostInfo(pluginVersion: string): HostInfo {
  const listeners: ((t: string) => void)[] = [];
  document.theme?.onUpdated.addListener((t) => listeners.forEach((cb) => cb(t)));
  return {
    packages: ["ccx"],
    appName: uxp.host.name,
    appVersion: uxp.host.version,
    pluginVersion,
    os: os.platform().toLowerCase().startsWith("win") ? "windows" : "macos",
    theme: () => document.theme?.getCurrent() ?? "dark",
    onTheme: (cb) => { listeners.push(cb); },
  };
}
