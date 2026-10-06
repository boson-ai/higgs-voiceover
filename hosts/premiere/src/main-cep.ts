// Entry point of the CEP build: Premiere loads index.html in its Chromium
// panel, which loads this bundle; cep/jsx/host.jsx is loaded into
// ExtendScript by the manifest.

import { createCepHost } from "./host/cep/index.ts";
import { startLog } from "./app/log.ts";
import { openStore } from "./app/store.ts";
import { Client } from "./app/client.ts";
import { startPanel } from "./ui/panel.ts";

declare const __VERSION__: string;

async function boot() {
  const host = createCepHost(__VERSION__, document.getElementById("media") as HTMLVideoElement, document.getElementById("media-samples") as HTMLVideoElement);
  const log = await startLog(host.files, __VERSION__);
  log.info("start", { version: __VERSION__, build: "cep", app: `${host.info.appName} ${host.info.appVersion}`, os: host.info.os });
  const store = await openStore(host.files, host.secrets);
  const client = new Client(host.http, () => store.key, __VERSION__, log);
  startPanel({ host, log, store, client });
}

window.addEventListener("DOMContentLoaded", () => {
  boot().catch((e) => console.error("Higgs VoiceOver failed to start", e));
});
