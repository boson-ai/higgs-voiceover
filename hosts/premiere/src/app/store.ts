// Settings, the API key and per-project drafts, in the plugin's data folder.
//
// The settings file has the Resolve build's shape and schema (core/settings),
// so behaviour and migrations stay one definition. The key does not go in
// it: Premiere gives plugins an encrypted store, which the file layout of
// the Resolve build had to do without.

import type { Files, Secrets } from "../host/host.ts";
import * as Settings from "../core/settings.ts";
import { sanitize } from "../core/text.ts";

export type Config = Settings.Config;

const KEY_NAME = "boson_api_key";

export interface Store {
  cfg: Config;
  key: string;
  save(): Promise<boolean>;
  setKey(key: string): Promise<boolean>;
  outputDir(projectName: string): string;
  defaultOutputDir(): string;
  loadDraft(projectId: string): Promise<{ text: string; voice: string | null } | null>;
  saveDraft(projectId: string, text: string, voice: string | null): Promise<boolean>;
}

export async function openStore(files: Files, secrets: Secrets): Promise<Store> {
  const path = files.join(files.dataDir, "config.json");
  const defaultOutputDir = () => files.join(files.mediaDir, "Higgs VoiceOver");
  let raw: unknown = null;
  const text = await files.readText(path);
  if (text) {
    try { raw = JSON.parse(text); } catch {
      // A damaged file is kept aside rather than silently replaced.
      await files.write(path + ".bad", text);
    }
  }
  const cfg = Settings.load(raw);
  if (!cfg.output_dir) cfg.output_dir = defaultOutputDir();
  const draftPath = (id: string) => files.join(files.dataDir, "projects", sanitize(id || "no-project") || "no-project", "generate.json");

  const store: Store = {
    cfg,
    key: await secrets.get(KEY_NAME),
    save: () => files.write(path, JSON.stringify(store.cfg, null, 2)),
    async setKey(key) {
      const ok = await secrets.set(KEY_NAME, key);
      if (ok) store.key = key;
      return ok;
    },
    defaultOutputDir,
    // The chosen folder plus the project's own name, so two projects never
    // mix their takes. Without a project the base folder is used.
    outputDir(projectName) {
      const base = store.cfg.output_dir || defaultOutputDir();
      const leaf = sanitize(projectName);
      return leaf ? files.join(base, leaf) : base;
    },
    async loadDraft(id) {
      const t = await files.readText(draftPath(id));
      if (!t) return null;
      try {
        const d = JSON.parse(t);
        return { text: String(d.text ?? ""), voice: typeof d.voice === "string" ? d.voice : null };
      } catch { return null; }
    },
    saveDraft: (id, text, voice) => files.write(draftPath(id), JSON.stringify({ text, voice, saved: Math.floor(Date.now() / 1000) })),
  };
  return store;
}
