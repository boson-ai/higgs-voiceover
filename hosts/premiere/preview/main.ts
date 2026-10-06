// The panel in a browser, on the stand-in host (mock-host.ts).
//
//   npm run preview, then open http://localhost:5178/?state=<state>&theme=<theme>
//   state: setup | empty | text | done | placed | settings | addvoice   theme: darkest | dark | light
//   host:  cep (microphone, native captions — the default) | uxp (file-only voices, subtitles to the bin)

import { createMockHost } from "./mock-host.ts";
import { startLog } from "../src/app/log.ts";
import { openStore } from "../src/app/store.ts";
import { Client } from "../src/app/client.ts";
import { startPanel } from "../src/ui/panel.ts";

const SAMPLE = [
  "<|emotion:elation|>Welcome back to the channel.",
  "Today we look at three ways to light a small room without buying anything new.",
  "First, move the lamp you already own.<|sfx:laughter|>Haha",
].join("\n");

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
const click = (id: string) => (document.getElementById(id) as HTMLElement).click();

async function main() {
  const q = new URLSearchParams(location.search);
  const state = q.get("state") ?? "done";
  const host = createMockHost(document.getElementById("media") as HTMLVideoElement, {
    key: state === "setup" ? "" : "bai-preview",
    theme: q.get("theme") ?? "darkest",
    sequence: q.get("sequence") !== "none",
    cep: q.get("host") !== "uxp",
    samplesMedia: document.getElementById("media-samples") as HTMLVideoElement,
  });
  const log = await startLog(host.files, "0.1.0-preview");
  const store = await openStore(host.files, host.secrets);
  store.cfg.auto_preview = false;
  if (state === "placed") { store.cfg.auto_place = true; store.cfg.auto_subtitles = true; }
  const client = new Client(host.http, () => store.key, "0.1.0-preview", log);
  startPanel({ host, log, store, client });
  await wait(50);
  const box = document.getElementById("text") as HTMLTextAreaElement;
  if (state !== "setup" && state !== "empty") {
    box.value = SAMPLE;
    box.dispatchEvent(new Event("input"));
  }
  if (state === "done" || state === "placed") {
    click("generate");
    await wait(200);
    while (!(document.getElementById("stop") as HTMLButtonElement).disabled) await wait(100);
  }
  if (q.get("play")) click("play");
  if (state === "settings") click("tab-settings");
  if (q.get("dirty")) {
    const track = document.getElementById("set-track") as HTMLInputElement;
    track.value = "Voice-over";
    track.dispatchEvent(new Event("input"));
  }
  if (state === "addvoice") click("voice-add");
  if (q.get("tab") === "file") click("av-tab-file");
  if (q.get("transcript")) click("av-has-text");
  if (q.get("record") === "take") {
    click("av-rec");
    await wait(3400);
    await wait(2600);
    click("av-rec");
    await wait(300);
  }
  // Visual checks: hover=<id>,<id> shows those elements as if the pointer were on them.
  const hover = (q.get("hover") ?? "").split(",").filter(Boolean);
  if (hover.length) {
    const rules = [...document.styleSheets].flatMap((sheet) => [...sheet.cssRules])
      .filter((r) => r instanceof CSSStyleRule && r.selectorText.includes(":hover"))
      .map((r) => r.cssText.replaceAll(":hover", ".force-hover"));
    const style = document.createElement("style");
    style.textContent = rules.join("\n");
    document.head.appendChild(style);
    for (const id of hover) document.getElementById(id)?.classList.add("force-hover");
  }
  document.body.dataset.ready = "1";
  (window as unknown as { host: unknown }).host = host;
}

window.addEventListener("DOMContentLoaded", () => { void main(); });
