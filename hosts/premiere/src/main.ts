// Entry point: Premiere loads index.html, which loads this bundle.

import { createUxpHost } from "./host/uxp/index.ts";
import { startLog } from "./app/log.ts";
import { openStore } from "./app/store.ts";
import { Client } from "./app/client.ts";
import { startPanel } from "./ui/panel.ts";

declare const __VERSION__: string;

async function boot() {
  const host = await createUxpHost(__VERSION__, document.getElementById("media") as HTMLVideoElement, document.getElementById("media-samples") as HTMLVideoElement);
  const log = await startLog(host.files, __VERSION__);
  log.info("start", { version: __VERSION__, app: `${host.info.appName} ${host.info.appVersion}`, os: host.info.os });
  const store = await openStore(host.files, host.secrets);
  const client = new Client(host.http, () => store.key, __VERSION__, log);
  startPanel({ host, log, store, client });
}

const uxp = require("uxp") as typeof import("uxp");
uxp.entrypoints.setup({
  panels: {
    main: {
      show() {
        // Premiere calls show once (UXP known issue); boot once either way.
        if (!(globalThis as { __higgsBooted?: boolean }).__higgsBooted) {
          (globalThis as { __higgsBooted?: boolean }).__higgsBooted = true;
          boot().catch((e) => console.error("Higgs VoiceOver failed to start", e));
        }
      },
    },
  },
});
