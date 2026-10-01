// Files through UXP's Node-like `fs` (manifest: localFileSystem "fullAccess",
// so plain native paths work) and its pickers. Every call is async in UXP;
// the sync variants throw.

import type { Files } from "../host.ts";

const uxp = require("uxp") as typeof import("uxp");
const fs = require("fs") as typeof import("fs");
const os = require("os") as typeof import("os");

export async function createFiles(): Promise<Files> {
  const windows = os.platform().toLowerCase().startsWith("win");
  const sep = windows ? "\\" : "/";
  const home = os.homedir();
  const dataDir = (await uxp.storage.localFileSystem.getDataFolder()).nativePath;

  const join = (...parts: string[]): string =>
    parts.filter((p) => p !== "").join(sep).replace(windows ? /[\\/]+/g : /\/+/g, sep);
  const basename = (p: string): string => p.split(/[\\/]/).pop() ?? p;
  const dirname = (p: string): string => {
    const i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"));
    return i > 0 ? p.slice(0, i) : p;
  };

  async function exists(path: string): Promise<boolean> {
    try { await fs.lstat(path); return true; } catch { return false; }
  }

  async function mkdirs(path: string): Promise<boolean> {
    if (await exists(path)) return true;
    try { await fs.mkdir(path, { recursive: true }); return true; } catch { return false; }
  }

  // An entry from a picker gives its native path; the plugin works in paths.
  const pathOf = (e: unknown): string | null => {
    const one = Array.isArray(e) ? e[0] : e;
    return one && typeof one === "object" && "nativePath" in one ? String((one as { nativePath: string }).nativePath) : null;
  };

  return {
    dataDir,
    home,
    mediaDir: join(home, windows ? "Videos" : "Movies"),
    sep,
    join,
    basename,
    dirname,
    exists,
    async read(path) {
      try {
        const buf = await fs.readFile(path);
        // UXP hands back a proxy ArrayBuffer; copy it before working on it.
        return typeof buf === "string" ? null : new Uint8Array(buf).slice();
      } catch { return null; }
    },
    async readText(path) {
      try { return String(await fs.readFile(path, { encoding: "utf-8" })); } catch { return null; }
    },
    async write(path, data) {
      try {
        await mkdirs(dirname(path));
        if (typeof data === "string") await fs.writeFile(path, data, { encoding: "utf-8" });
        else await fs.writeFile(path, data);
        return true;
      } catch { return false; }
    },
    mkdirs,
    async list(path) {
      try { return await fs.readdir(path); } catch { return []; }
    },
    async remove(path) {
      try { await fs.unlink(path); return true; } catch { return false; }
    },
    async size(path) {
      try { return (await fs.lstat(path)).size; } catch { return null; }
    },
    async pickOpen(types) {
      return pathOf(await uxp.storage.localFileSystem.getFileForOpening({ types }));
    },
    async pickSave(name, types) {
      return pathOf(await uxp.storage.localFileSystem.getFileForSaving(name, { types }));
    },
    async pickFolder() {
      return pathOf(await uxp.storage.localFileSystem.getFolder());
    },
  };
}
