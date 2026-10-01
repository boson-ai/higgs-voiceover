// The Higgs VoiceOver panel: onboarding, Generate and Settings.
//
// The same product as the Resolve window (hosts/resolve/src/higgs/ui.lua):
// same layout, words and rules, in Premiere's look. Where Premiere differs it
// says so here:
//   * tags are coloured in the text box where the panel is Chromium (CEP);
//     UXP cannot colour part of an editable field, so there it is plain;
//   * Add a voice records only where the host has a microphone (CEP);
//     UXP gives panels none, so it takes a file;
//   * subtitles land in the bin as an .srt to drag in (app/placing.ts);
//   * an update is downloaded in the browser and installed by opening it.

import type { Host, Take } from "../host/host.ts";
import type { Log } from "../app/log.ts";
import type { Store } from "../app/store.ts";
import { $, input, area, select, on, show, enable, say, el, setChoice } from "./dom.ts";
import * as Text from "../core/text.ts";
import * as Tags from "../core/tags.ts";
import * as Boson from "../core/boson.ts";
import * as Wav from "../core/wav.ts";
import * as Rec from "../core/recorder.ts";
import * as Settings from "../core/settings.ts";
import { Client } from "../app/client.ts";
import { placeTakes } from "../app/placing.ts";
import { checkForUpdate } from "../app/updates.ts";
import { attachHighlighter } from "./editor.ts";

const KEY_URL = "https://www.boson.ai/workspace/api-key";

interface Deps { host: Host; log: Log; store: Store; client: Client }

type Kind = "ok" | "error" | "run" | undefined;

export function startPanel({ host, log, store, client }: Deps): void {
  const cfg = () => store.cfg;
  const files = host.files;

  // ------------------------------------------------------------- state

  const st = {
    page: "generate" as "setup" | "generate" | "settings",
    skipped: false,
    connected: false,
    voice: null as string | null,          // the voice this project's draft uses
    pickedVoice: null as string | null,    // highlighted in the list, not yet used
    pickedTag: -1,
    busy: false,
    stopped: false,
    progress: null as { index: number; total: number } | null,
    dots: 0,
    note: null as { text: string; kind: Kind } | null,
    takes: [] as Take[],
    run: null as { takes: Take[]; total: number } | null,
    index: 0,
    abort: null as AbortController | null,
    project: { id: "", name: "" },
    dirtyAt: 0,
    previewing: null as string | null,     // voice id of a sample playing
  };

  // ------------------------------------------------------------- chip, tabs

  function refreshChip() {
    const chip = $("conn");
    chip.classList.remove("connected", "saved");
    if (!store.key) say("conn-text", "No API key");
    else if (st.connected) { chip.classList.add("connected"); say("conn-text", "Connected"); }
    else { chip.classList.add("saved"); say("conn-text", "Key saved"); }
  }

  function route(page?: "generate" | "settings") {
    if (page) st.page = page;
    const setup = !store.key && !st.skipped;
    show("page-setup", setup);
    show("page-generate", !setup && st.page === "generate");
    show("page-settings", !setup && st.page === "settings");
    // First run is one screen: no tabs, no chip, no header.
    show("topbar", !setup);
    $("tab-generate").classList.toggle("active", st.page === "generate");
    $("tab-settings").classList.toggle("active", st.page === "settings");
    if (!setup && st.page === "settings") fillSettings(values(cfg(), store.key), true);
  }

  on("tab-generate", "click", () => route("generate"));
  on("tab-settings", "click", () => route("settings"));

  function applyTheme(theme: string) {
    document.body.classList.remove("theme-darkest", "theme-dark", "theme-light");
    document.body.classList.add(theme.includes("light") ? "theme-light" : theme === "dark" ? "theme-dark" : "theme-darkest");
  }
  applyTheme(host.info.theme());
  host.info.onTheme(applyTheme);

  // ------------------------------------------------------------- key checks

  async function testKey(key: string, resultId: string, context: "setup" | "settings") {
    if (!key) { say(resultId, "Paste your API key first.", "error"); return; }
    say(resultId, "Checking the key…");
    const res = await client.test(key);
    log.metric("key.test", { ok: res.ok ? 1 : 0, where: context, code: res.code ?? "" });
    const isSaved = context === "settings" && key === store.key;
    if (res.ok) {
      if (context === "setup") {
        // A first run keeps the key only once it works: a typo must not
        // skip onboarding next time.
        await store.setKey(key);
        st.connected = true;
      } else if (isSaved) st.connected = true;
      say(resultId, "●  Connected", "ok");
      refreshChip();
      route();
      if (context === "setup" || isSaved) note("Connected", "ok");
    } else {
      if (isSaved) st.connected = false;
      refreshChip();
      say(resultId, res.code === "401" ? "Boson didn't accept that key. Check that you copied all of it." : (res.error ?? "Couldn't connect to Boson."), "error");
    }
  }

  const openKeyPage = () => { log.ui("open get-a-key page"); void host.shell.openUrl(KEY_URL); };

  // ------------------------------------------------------------- setup

  on("setup-get-key", "click", openKeyPage);
  on("setup-show", "change", () => { input("setup-key").type = input("setup-show").checked ? "text" : "password"; });
  on("setup-key", "input", () => say("setup-result", ""));
  on("setup-key", "keydown", (e) => { if ((e as KeyboardEvent).key === "Enter") void testKey(input("setup-key").value.trim(), "setup-result", "setup"); });
  on("setup-connect", "click", () => void testKey(input("setup-key").value.trim(), "setup-result", "setup"));
  on("setup-skip", "click", () => {
    log.metric("setup.skip");
    st.skipped = true;
    route("generate");
    note("No API key yet — add one in Settings before you generate.");
  });

  // ------------------------------------------------------------- voices

  interface VoiceEntry { id: string; label: string; own: boolean }

  function voiceEntries(): VoiceEntry[] {
    const out: VoiceEntry[] = Boson.PRESET_VOICES.map((v) => ({ id: v.id, label: v.label, own: false }));
    for (const v of cfg().voices ?? []) out.push({ id: v.id, label: v.name || "Cloned voice", own: true });
    return out;
  }
  const currentVoice = () => st.voice ?? cfg().default_voice;

  function renderVoices() {
    const list = $("voice-list");
    list.textContent = "";
    for (const v of voiceEntries()) {
      const row = el("div", "item");
      if (v.id === currentVoice()) row.classList.add("in-use");
      if (v.id === st.pickedVoice) row.classList.add("selected");
      row.appendChild(el("span", "star", v.id === currentVoice() ? "★" : ""));
      row.appendChild(el("span", "name ellipsis", v.label));
      row.addEventListener("click", () => { st.pickedVoice = v.id; renderVoices(); });
      row.addEventListener("dblclick", () => { st.pickedVoice = v.id; useVoice(); });
      list.appendChild(row);
    }
    const picked = voiceEntries().find((v) => v.id === st.pickedVoice);
    enable("voice-delete", !!picked?.own);
    // Live only when it would change something.
    enable("voice-use", !!picked && picked.id !== currentVoice());
    $("voice-delete").title = picked?.own ? "Remove this voice from your list. It stays on your Boson account."
      : picked ? "Built-in voices cannot be deleted." : "Pick a voice in the list first.";
    say("voice-preview", st.previewing ? "Stop" : "Preview");
  }

  function useVoice() {
    const v = voiceEntries().find((e) => e.id === st.pickedVoice);
    if (!v) { note("Pick a voice in the list first."); return; }
    log.metric("voice.use", { voice: Boson.isPreset(v.id) ? v.id : "cloned" });
    st.voice = v.id;
    st.dirtyAt = Date.now();
    renderVoices();
    refresh();
  }
  on("voice-use", "click", useVoice);

  on("voice-delete", "click", async () => {
    const v = voiceEntries().find((e) => e.id === st.pickedVoice);
    if (!v || !v.own) return;
    cfg().voices = (cfg().voices ?? []).filter((x) => x.id !== v.id);
    // A deleted voice cannot stay the one in use.
    if (st.voice === v.id) { st.voice = null; st.dirtyAt = Date.now(); }
    if (cfg().default_voice === v.id) cfg().default_voice = Settings.DEFAULTS.default_voice;
    await store.save();
    log.metric("voice.delete", { where: "generate" });
    st.pickedVoice = null;
    renderVoices();
    note(`Deleted “${v.label}” from your list.`, "ok");
  });

  // A sample of a voice: generated once, then kept. One thing plays at a time.
  on("voice-preview", "click", async () => {
    if (st.previewing) { host.player.stop(); return; }
    const v = voiceEntries().find((e) => e.id === st.pickedVoice);
    if (!v) { note("Pick a voice in the list first."); return; }
    const path = files.join(files.dataDir, "previews", Text.sanitize(v.id) + ".wav");
    if (!(await files.exists(path))) {
      say("voice-preview", "Loading…");
      log.metric("voice.preview", { voice: Boson.isPreset(v.id) ? v.id : "cloned" });
      const res = await client.speech({ text: "Here's how this voice sounds reading your script.", voice: v.id, format: "wav" });
      if (!res.ok || !res.audio) { say("voice-preview", "Preview"); note(res.error ?? `Could not generate a preview of ${v.label}.`, "error"); return; }
      await files.write(path, res.audio);
    }
    const sample = await files.read(path);
    host.player.load(path, (sample && Wav.wavSeconds(sample)) ?? 3);
    st.previewing = v.id;
    host.player.play();
    renderVoices();
  });

  on("voice-add", "click", () => openAddVoice());

  // ------------------------------------------------------------- tags

  interface TagRow { cat: string; value: string; label: string; lineStart: boolean }
  const TAG_TYPES = ["All types", "Emotion", "Style", "Speed", "Pitch", "Expressiveness", "Pause", "Sound effect"];
  const KIND_CLASS: Record<string, string> = {
    Emotion: "k-emotion", Style: "k-style", Speed: "k-speed", Pitch: "k-pitch",
    Expressiveness: "k-expressive", Pause: "k-pause", "Sound effect": "k-sfx",
  };
  const titleCase = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

  // Emotion, style, speed, pitch and expressiveness set up the whole line,
  // so they go to its start and replace one of the same kind; pauses and
  // sound effects go where the caret is.
  function tagRows(): TagRow[] {
    const rows: TagRow[] = [];
    const add = (cat: string, value: string, label: string, lineStart: boolean) => rows.push({ cat, value, label: titleCase(label), lineStart });
    for (const e of Tags.EMOTIONS) add("Emotion", "emotion:" + e, e, true);
    for (const s of Tags.STYLES) add("Style", "style:" + s, s, true);
    for (const v of Tags.SPEEDS) if (v.value) add("Speed", "prosody:" + v.value, v.label, true);
    for (const v of Tags.PITCHES) if (v.value) add("Pitch", "prosody:" + v.value, v.label, true);
    for (const v of Tags.EXPRESSIVENESS) if (v.value) add("Expressiveness", "prosody:" + v.value, v.label, true);
    for (const v of Tags.PAUSES) add("Pause", v.value, v.label, false);
    for (const x of Tags.SFX) add("Sound effect", "sfx:" + x, x, false);
    return rows;
  }
  const ALL_TAGS = tagRows();
  let shownTags: TagRow[] = [];

  for (const t of TAG_TYPES) { const o = el("option", undefined, t) as HTMLOptionElement; o.value = t; select("tag-type").appendChild(o); }
  setChoice("tag-type", "All types");

  function renderTags() {
    const want = select("tag-type").value || "All types";
    const needle = input("tag-search").value.trim().toLowerCase();
    shownTags = ALL_TAGS.filter((r) => (want === "All types" || want === r.cat)
      && (!needle || r.label.toLowerCase().includes(needle) || r.cat.toLowerCase().includes(needle)));
    const list = $("tag-list");
    list.textContent = "";
    shownTags.forEach((r, i) => {
      const row = el("div", "item" + (i === st.pickedTag ? " selected" : ""));
      row.appendChild(el("span", "name ellipsis", r.label));
      row.appendChild(el("span", "kind " + (KIND_CLASS[r.cat] ?? ""), r.cat));
      row.addEventListener("click", () => { st.pickedTag = i; renderTags(); });
      row.addEventListener("dblclick", () => { st.pickedTag = i; insertTag(); });
      list.appendChild(row);
    });
    const r = shownTags[st.pickedTag];
    show("tag-foot", !!r?.lineStart);
    say("tag-foot", r?.lineStart ? `${r.cat} tags go to the start of the line automatically.` : "");
  }
  on("tag-type", "change", () => { st.pickedTag = -1; renderTags(); });
  on("tag-search", "input", () => { st.pickedTag = -1; renderTags(); });

  // The caret is remembered when the box loses focus to a list or button.
  let caret = { start: 0, end: 0 };
  const box = area("text");
  const highlighter = host.richText ? attachHighlighter(box, $("text-mirror"), $("editor")) : null;
  const keepCaret = () => { caret = { start: box.selectionStart ?? 0, end: box.selectionEnd ?? 0 }; };
  for (const ev of ["keyup", "mouseup", "blur", "input"]) box.addEventListener(ev, keepCaret);

  function insertTag() {
    const r = shownTags[st.pickedTag];
    if (!r) { note("Pick a tag in the list first."); return; }
    if (st.busy) return;
    const text = box.value;
    const { text: out, caret: at } = Tags.placeTag(text.slice(0, caret.start), text.slice(caret.end), r.value, r.lineStart);
    box.value = out;
    box.focus();
    box.setSelectionRange(at, at);
    caret = { start: at, end: at };
    log.metric("tag.insert", { type: r.cat, tag: r.value, moved_to_line_start: r.lineStart ? 1 : 0 });
    textChanged();
  }
  on("tag-insert", "click", insertTag);

  // ------------------------------------------------------------- text

  interface Line { text: string; composed: string; chars: number }

  function lines(): { lines: Line[]; chars: number; over: number } {
    let chars = 0, over = 0;
    const out = Text.splitLines(box.value).map((text, i) => {
      const composed = Tags.compose(text, null);
      const n = Text.utf8Len(Text.trim(composed));
      chars += n;
      if (n > Boson.MAX_INPUT_CHARS && !over) over = i + 1;
      return { text, composed, chars: n };
    });
    return { lines: out, chars, over };
  }

  function textChanged() {
    st.dirtyAt = Date.now();
    refresh();
  }
  box.addEventListener("input", textChanged);

  on("text-clear", "click", () => { if (!box.value) return; box.value = ""; textChanged(); });

  on("text-import", "click", async () => {
    const path = await files.pickOpen(["txt", "srt", "md"]);
    if (!path) return;
    let text = await files.readText(path);
    if (text === null) { note("Could not read that file.", "error"); return; }
    if (text.includes("\u0000")) { note("That does not look like a text file.", "error"); return; }
    // A byte-order mark (Windows editors add one) would be spoken and named.
    text = text.replace(/^﻿/, "").replace(/\r\n?/g, "\n");
    box.value = text;
    textChanged();
    note(`Imported ${files.basename(path)}.`, "ok");
  });

  on("text-export", "click", async () => {
    let path = await files.pickSave("Higgs VoiceOver.txt", ["txt"]);
    if (!path) return;
    if (!/\.txt$/i.test(path)) path += ".txt";
    if (await files.write(path, box.value)) {
      log.info("text exported", { path: log.q(log.pathSafe(path)) });
      note(`Saved ${files.basename(path)}.`, "ok");
    } else note("Could not write " + path, "error");
  });

  // ------------------------------------------------------------- status line

  function note(text: string, kind?: Kind) {
    st.note = { text, kind };
    refresh(true);
  }

  const fmtInt = (n: number) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",");

  /**
   * Everything on the Generate page that depends on state is written here, so
   * it always un-writes itself when the state that produced it goes away. A
   * message about something that just happened is kept until the next edit.
   */
  function refresh(keepNote = false) {
    if (!keepNote) st.note = null;
    highlighter?.paint();
    const { lines: ls, chars, over } = lines();
    const n = ls.length;
    enable("generate", n > 0 && !over && !st.busy);
    enable("stop", st.busy);
    // Nothing may change the text under a run that is already using it.
    box.readOnly = st.busy;
    enable("text-clear", box.value !== "" && !st.busy);
    enable("text-import", !st.busy);
    enable("tag-insert", !st.busy);

    // One clip: "Place on timeline". Several: the clip on show, or all.
    // They stay placeable while the text is edited; only a new run clears them.
    const count = st.takes.length;
    show("place-one", count > 1);
    say("place-all", count > 1 ? `Place all ${count} clips` : "Place on timeline");
    enable("place-all", count > 0);
    $("place-all").title = count === 0 ? "Generate something first."
      : count > 1 ? "Put every clip from this run on the timeline, in order, starting at the playhead."
      : "Put the clip on the timeline at the playhead.";
    void refreshWhere();

    let text = "", kind: Kind;
    if (over) {
      text = n > 1 ? `Line ${over} is over the ${fmtInt(Boson.MAX_INPUT_CHARS)}-character limit — split it with a line break.`
                   : `Over the ${fmtInt(Boson.MAX_INPUT_CHARS)}-character limit — break it into lines; each line becomes its own clip.`;
      kind = "error";
    } else if (st.busy) {
      const p = st.progress;
      text = (p && p.total > 1 ? `Generating ${p.index}/${p.total}` : "Generating") + ".".repeat(st.dots);
      kind = "run";
    } else if (st.note) {
      ({ text, kind } = st.note);
    } else if (n > 0) {
      text = `${n} line${n === 1 ? "" : "s"} · ${fmtInt(chars)} chars`;
    }
    say("status", text, kind === "run" ? "warn" : kind);
    $("status").title = text;
    refreshPlayer();
  }

  // The bin the run's clips are in, top right of the preview card. Empty
  // while there is nothing in it.
  async function refreshWhere() {
    if (st.takes.length === 0) { say("preview-where", ""); return; }
    const bin = await host.timeline.binName();
    say("preview-where", `Saved in the “${bin}” bin`);
    $("preview-where").title = `Project › ${bin}\nFiles: ${store.outputDir(st.project.name)}`;
  }

  // ------------------------------------------------------------- generate

  /** Where a take is written: named after its text as Settings asks, a number added only when the name is taken. */
  async function clipPath(text: string, dir: string, ext: string): Promise<string> {
    const o = cfg().clip_name ?? {};
    const d = new Date();
    const p2 = (x: number) => String(x).padStart(2, "0");
    const parts: string[] = [];
    if (o.words !== false) parts.push(Text.clipWords(text, 4));
    if (o.date) parts.push(`${d.getFullYear()}${p2(d.getMonth() + 1)}${p2(d.getDate())}`);
    if (o.time) parts.push(`${p2(d.getHours())}${p2(d.getMinutes())}${p2(d.getSeconds())}`);
    const base = parts.filter(Boolean).join("_");
    if (!base) {
      let k = 1;
      while (await files.exists(files.join(dir, `${k}.${ext}`))) k++;
      return files.join(dir, `${k}.${ext}`);
    }
    let name = base, k = 2;
    while (await files.exists(files.join(dir, `${name}.${ext}`))) name = `${base}_${k++}`;
    return files.join(dir, `${name}.${ext}`);
  }

  /** Boson returns mono: both channels carry it so the clip is centred; then the pause (wav only). */
  function finishAudio(bytes: Uint8Array, ext: string): { bytes: Uint8Array; pause: number } {
    if (ext !== "wav") return { bytes, pause: 0 };
    let out = Wav.wavToStereo(bytes) ?? bytes;
    let pause = 0;
    const ms = Number(cfg().pause_ms) || 0;
    if (cfg().pause_enabled !== false && ms > 0) {
      const padded = Wav.wavAppendSilence(out, ms / 1000);
      if (padded) { out = padded; pause = ms / 1000; } else log.warn("could not append silence");
    }
    return { bytes: out, pause };
  }

  on("generate", "click", async () => {
    const { lines: ls, chars, over } = lines();
    if (ls.length === 0 || over || st.busy) return;
    if (!store.key) { note("Add your Boson API key in Settings before you generate.", "error"); return; }
    const voice = currentVoice();
    // Word timings only when subtitles may be wanted: asking for them
    // changes the request (Boson then skips text normalisation).
    const timed = cfg().auto_subtitles === true || cfg().manual_subtitles === true;
    const ext = cfg().output_format || "wav";
    const dir = store.outputDir(st.project.name);
    await files.mkdirs(dir);
    host.player.stop();
    const takes: Take[] = [];
    const t0 = Date.now();
    log.info("generate", { lines: ls.length, chars, voice: Boson.isPreset(voice) ? voice : "cloned", timestamps: timed ? 1 : 0 });
    const runMetric = (result: string) => log.metric("generate.quick", {
      lines: ls.length, made: takes.length, chars, result, ms: Date.now() - t0,
      audio_seconds: takes.reduce((a, t) => a + t.seconds, 0),
      auto_preview: cfg().auto_preview !== false ? 1 : 0, auto_place: cfg().auto_place ? 1 : 0, subtitles: timed ? 1 : 0,
    });

    st.busy = true; st.stopped = false; st.takes = []; st.index = 0;
    st.run = { takes, total: ls.length };
    st.abort = new AbortController();
    const signal = st.abort.signal;
    loadTake();

    // One line at a time, in order, so the clips land in order too.
    for (let i = 0; i < ls.length; i++) {
      st.progress = { index: i + 1, total: ls.length };
      refresh();
      const line = ls[i];
      const res = await client.speech({ text: Tags.terminate(line.composed), voice, format: ext, timestamps: timed }, signal);
      if (st.stopped) return;
      if (!res.ok || !res.audio) {
        st.busy = false; st.progress = null;
        // Lines already made are kept, as Stop keeps them.
        st.takes = takes;
        loadTake();
        runMetric("failed");
        note(ls.length > 1 ? `Line ${i + 1} — ${res.error}` : String(res.error), "error");
        return;
      }
      const path = await clipPath(line.text, dir, ext);
      const { bytes, pause } = finishAudio(res.audio, ext);
      if (!(await files.write(path, bytes))) {
        st.busy = false; st.progress = null; st.takes = takes; loadTake();
        runMetric("failed");
        note(`Could not write ${files.basename(path)}.`, "error");
        return;
      }
      // Into the bin straight away, so it is in the project whether or not it is placed.
      const imp = await host.timeline.importToBin([path]);
      if (!imp.ok) log.warn("import failed", { error: imp.error });
      // The line and its word timings travel with the take, so placing it
      // later can still add its subtitles.
      takes.push({ path, seconds: (ext === "wav" ? Wav.wavSeconds(bytes) : null) ?? Text.estimateSeconds(line.text), text: line.text, words: res.words, pause });
    }
    st.busy = false; st.progress = null;
    st.takes = takes; st.index = 0;
    loadTake();
    runMetric("done");
    note(ls.length > 1 ? `${ls.length}/${ls.length} generated` : "Generated", "ok");
    if (cfg().auto_preview !== false) host.player.play();
    if (cfg().auto_place) await place(takes, "auto");
  });

  on("stop", "click", () => {
    if (!st.busy) return;
    st.abort?.abort();
    st.stopped = true; st.busy = false; st.progress = null;
    const made = st.run?.takes.length ?? 0;
    // What was already generated is kept: it is on disk and in the bin.
    if (made > 0) { st.takes = st.run!.takes; st.index = 0; loadTake(); }
    log.metric("generate.quick", { result: "stopped", made });
    note(made > 0 ? `Stopped — ${made} of ${st.run?.total ?? made} generated` : "Stopped");
  });

  // Dots move while a request is out, so a long line looks alive.
  setInterval(() => { if (st.busy) { st.dots = (st.dots + 1) % 4; refresh(true); } }, 450);

  // ------------------------------------------------------------- preview

  const take = () => st.takes[st.index];

  function loadTake() {
    st.previewing = null;
    const t = take();
    if (t) host.player.load(t.path, t.seconds);
    else host.player.stop();
    refresh(true);
  }

  const mmss = (s: number) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;

  function refreshPlayer() {
    const t = take();
    const n = st.takes.length;
    $("preview").classList.toggle("empty", !t);
    show("take-index", !!t);
    say("take-index", t ? `${st.index + 1}/${n}` : "");
    say("take-name", t ? files.basename(t.path) : "Nothing to preview yet — Generate to hear your lines.");
    enable("take-prev", st.index > 0);
    enable("take-next", st.index < n - 1);
    enable("play", !!t || !!st.previewing);
    enable("pause-stop", !!t || !!st.previewing);
    const p = host.player;
    const playing = p.state === "playing";
    $("play-glyph").className = playing ? "g g-pause" : "g g-play";
    $("play").title = playing ? "Pause" : "Play";
    const dur = p.duration || (t?.seconds ?? 0);
    say("time-now", mmss(p.position));
    say("time-total", mmss(dur));
    $("bar-fill").style.width = `${dur > 0 ? Math.round(Math.min(1, p.position / dur) * ($("bar").clientWidth || 0)) : 0}px`;
  }

  // A voice sample borrows the player; when it ends the take on show comes back.
  host.player.onChange(() => {
    if (st.previewing && host.player.state === "stopped") { renderVoices(); loadTake(); return; }
    refreshPlayer();
  });
  on("play", "click", () => {
    const p = host.player;
    log.metric("preview.play", { action: p.state === "playing" ? "pause" : "play", take: st.index + 1 });
    if (p.state === "playing") p.pause(); else p.play();
  });
  on("pause-stop", "click", () => host.player.stop());
  on("take-prev", "click", () => { if (st.index > 0) { st.index--; loadTake(); } });
  on("take-next", "click", () => { if (st.index < st.takes.length - 1) { st.index++; loadTake(); } });
  on("bar", "click", (e) => {
    const bar = $("bar");
    const x = (e as MouseEvent).offsetX;
    if (bar.clientWidth > 0) host.player.seek((x / bar.clientWidth) * host.player.duration);
  });

  // ------------------------------------------------------------- placing

  async function place(takes: Take[], mode: "auto" | "all" | "one") {
    // Automatic placing follows the box beside Generate; the Place buttons
    // follow the one in the audio preview.
    const subtitles = mode === "auto" ? cfg().auto_subtitles === true : cfg().manual_subtitles === true;
    const out = await placeTakes(host, log, takes, { trackName: cfg().vo_track_name, subtitles, split: cfg().subtitle_split, mode });
    note(out.message, out.kind);
  }
  on("place-all", "click", () => { if (st.takes.length) void place(st.takes, "all"); });
  on("place-one", "click", () => { const t = take(); if (t) void place([t], "one"); });

  // The Generate-page boxes save as they change; Settings' Save does not cover them.
  const box2cfg: [string, keyof Settings.Config][] = [
    ["auto-place", "auto_place"], ["auto-subs", "auto_subtitles"], ["auto-preview", "auto_preview"], ["preview-subs", "manual_subtitles"],
  ];
  for (const [id, key] of box2cfg) {
    on(id, "change", () => {
      (cfg() as unknown as Record<string, unknown>)[key] = input(id).checked;
      log.ui(`${key} ${input(id).checked ? "on" : "off"}`);
      void store.save();
    });
  }

  // ------------------------------------------------------------- drafts

  // The draft (text + voice) belongs to the open project: written two
  // seconds after the last edit, and loaded when the project changes.
  async function followProject() {
    const id = await host.timeline.projectId();
    const name = await host.timeline.projectName();
    st.project.name = name;
    if (id === st.project.id) return;
    if (st.dirtyAt) await saveDraft();
    st.project.id = id;
    const d = await store.loadDraft(id);
    box.value = d?.text ?? "";
    st.voice = d?.voice ?? null;
    st.dirtyAt = 0;
    renderVoices();
    refresh();
  }
  async function saveDraft() {
    st.dirtyAt = 0;
    if (!(await store.saveDraft(st.project.id, box.value, st.voice))) note("Could not save the draft.", "error");
  }
  setInterval(() => {
    void followProject();
    if (st.dirtyAt && Date.now() - st.dirtyAt > 2000) void saveDraft();
  }, 1000);

  // ------------------------------------------------------------- settings

  const SPLITS: Record<string, string> = {
    short: "Split sentences into shorter segments.",
    sentence: "Display a whole sentence at once.",
  };

  interface Values {
    key: string; output_dir: string; vo_track_name: string; output_format: string;
    pause_enabled: boolean; pause_ms: number; check_updates: boolean; subtitle_split: string;
    words: boolean; date: boolean; time: boolean;
  }

  // The page as values, in one shape whether read from the fields, the
  // saved config or the defaults — so "unsaved" and "already default" are
  // the same comparison.
  function values(c: Settings.Config, key: string): Values {
    const o = c.clip_name ?? {};
    return {
      key,
      output_dir: c.output_dir || store.defaultOutputDir(),
      vo_track_name: c.vo_track_name,
      output_format: c.output_format,
      pause_enabled: c.pause_enabled !== false,
      pause_ms: Number(c.pause_ms) || 400,
      check_updates: c.check_updates !== false,
      subtitle_split: c.subtitle_split || "short",
      words: o.words !== false, date: !!o.date, time: !!o.time,
    };
  }

  function fromFields(): Values {
    const ms = Number(input("set-pause-ms").value);
    return {
      key: input("set-key").value.trim(),
      output_dir: input("set-out-dir").value.trim() || store.defaultOutputDir(),
      vo_track_name: input("set-track").value.trim() || Settings.DEFAULTS.vo_track_name,
      output_format: select("set-format").value || "wav",
      pause_enabled: input("set-pause").checked,
      pause_ms: Math.max(0, Math.min(5000, Number.isFinite(ms) && input("set-pause-ms").value.trim() !== "" ? ms : 400)),
      check_updates: input("set-auto-update").checked,
      subtitle_split: select("set-split").value || "short",
      words: input("set-name-words").checked, date: input("set-name-date").checked, time: input("set-name-time").checked,
    };
  }

  const same = (a: Values, b: Values, ignoreKey = false) =>
    (Object.keys(a) as (keyof Values)[]).every((k) => (ignoreKey && k === "key") || a[k] === b[k]);

  function fillSettings(v: Values, withKey: boolean) {
    if (withKey) input("set-key").value = v.key;
    input("set-out-dir").value = v.output_dir;
    input("set-track").value = v.vo_track_name;
    setChoice("set-format", v.output_format);
    input("set-pause").checked = v.pause_enabled;
    input("set-pause-ms").value = String(v.pause_ms);
    input("set-auto-update").checked = v.check_updates;
    setChoice("set-split", v.subtitle_split);
    input("set-name-words").checked = v.words;
    input("set-name-date").checked = v.date;
    input("set-name-time").checked = v.time;
    say("set-version", host.info.pluginVersion);
    say("set-log", "This session: " + files.basename(log.path));
    refreshSettings();
  }

  let savedAt = 0;
  function refreshSettings() {
    const f = fromFields();
    const dirty = !same(f, values(cfg(), store.key));
    enable("set-save", dirty);
    enable("set-reset", !same(f, values(Settings.DEFAULTS as Settings.Config, store.key), true));
    say("set-split-hint", SPLITS[f.subtitle_split] ?? "");
    const leaf = Text.sanitize(st.project.name);
    say("set-out-project", leaf ? `${files.sep}  ${leaf.length > 24 ? leaf.slice(0, 23) + "…" : leaf}` : "");
    const parts: string[] = [];
    if (f.words) parts.push("Welcome_back_to_the");
    const d = new Date(), p2 = (x: number) => String(x).padStart(2, "0");
    if (f.date) parts.push(`${d.getFullYear()}${p2(d.getMonth() + 1)}${p2(d.getDate())}`);
    if (f.time) parts.push(`${p2(d.getHours())}${p2(d.getMinutes())}${p2(d.getSeconds())}`);
    say("set-name-preview", parts.length ? `e.g. ${parts.join("_")}.wav` : "Nothing ticked: clips are numbered 1.wav, 2.wav…");
    if (dirty) { savedAt = 0; say("set-status", "Unsaved changes"); }
    else if (!savedAt || Date.now() - savedAt > 2000) say("set-status", "");
  }
  for (const id of ["set-key", "set-out-dir", "set-track", "set-pause-ms"]) on(id, "input", refreshSettings);
  for (const id of ["set-format", "set-split", "set-pause", "set-auto-update", "set-name-words", "set-name-date", "set-name-time"]) on(id, "change", refreshSettings);
  on("set-show", "change", () => { input("set-key").type = input("set-show").checked ? "text" : "password"; });
  on("set-get-key", "click", openKeyPage);
  on("set-test", "click", () => void testKey(input("set-key").value.trim(), "set-key-result", "settings"));
  on("set-key", "input", () => say("set-key-result", ""));
  on("set-browse", "click", async () => {
    const dir = await files.pickFolder();
    if (dir) { input("set-out-dir").value = dir; refreshSettings(); }
  });
  on("set-open-log", "click", () => void host.shell.openFolder(files.dirname(log.path)));

  on("set-save", "click", async () => {
    const v = fromFields();
    const c = cfg();
    c.output_dir = v.output_dir; c.vo_track_name = v.vo_track_name; c.output_format = v.output_format;
    c.pause_enabled = v.pause_enabled; c.pause_ms = v.pause_ms; c.check_updates = v.check_updates;
    c.subtitle_split = v.subtitle_split;
    c.clip_name = { ...(c.clip_name ?? {}), words: v.words, date: v.date, time: v.time };
    if (v.key !== store.key) { await store.setKey(v.key); st.connected = false; refreshChip(); }
    const ok = await store.save();
    log.ui("settings saved", { ok: ok ? 1 : 0 });
    fillSettings(values(cfg(), store.key), true);
    savedAt = Date.now();
    say("set-status", ok ? "Saved" : "Couldn't save the settings.", ok ? undefined : "error");
    setTimeout(refreshSettings, 2100);
  });

  // Every field but the key gets its default, for Save to keep.
  on("set-reset", "click", () => {
    fillSettings({ ...values(Settings.DEFAULTS as Settings.Config, store.key), key: input("set-key").value.trim() }, false);
  });

  // ------------------------------------------------------------- updates

  const upd = { latest: null as string | null, page: "", asset: "", checking: false };

  async function checkUpdates(quiet: boolean) {
    if (upd.checking) return;
    upd.checking = true;
    say("set-update-status", "Checking…");
    log.info("update check" + (quiet ? " (automatic)" : ""));
    const r = await checkForUpdate(host.http, host.info.pluginVersion);
    upd.checking = false;
    cfg().last_update_check = Math.floor(Date.now() / 1000);
    if (!r.ok) {
      log.warn("update check failed", { error: r.error });
      say("set-update-status", quiet ? "" : titleCase(r.error ?? "couldn't check for updates"), "error");
      await store.save();
      return;
    }
    upd.latest = r.latest; upd.page = r.page ?? ""; upd.asset = r.asset ?? "";
    cfg().update_state = r.latest ? "available" : "current";
    await store.save();
    refreshUpdate();
    if (r.latest) note(`Higgs VoiceOver ${r.latest} is available — update from Settings.`, "ok");
  }

  function refreshUpdate() {
    show("set-check", !upd.latest);
    show("set-download", !!upd.latest);
    show("set-notes", !!upd.latest);
    if (upd.latest) say("set-update-status", `Version ${upd.latest} is available`, "ok");
    else if (cfg().update_state === "current") say("set-update-status", "Up to date");
  }
  on("set-check", "click", () => void checkUpdates(false));
  on("set-notes", "click", () => { if (upd.page) void host.shell.openUrl(upd.page); });
  // A plugin cannot install itself: the package is downloaded in the
  // browser and opened, and Creative Cloud installs it.
  on("set-download", "click", () => {
    if (!upd.asset) return;
    log.info("update: download in browser", { version: upd.latest });
    void host.shell.openUrl(upd.asset);
    say("set-update-status", "Open the downloaded file to install it");
  });

  // ------------------------------------------------------------- add a voice
  //
  // As in the Resolve dialog: Record | Use a file; a 3-2-1 count-in that is
  // not in the take; two take slots so "Record again" never loses the last
  // one; one line under the transport for guidance, the level while
  // recording, and the verdict on the take (core/recorder). Record is there
  // only when the host has a microphone (the CEP build); UXP shows the file
  // page alone.

  const dlg = $("add-voice") as HTMLDialogElement;
  const REC_LIMIT = Rec.GOOD_MAX;
  const COUNT_IN = 3;
  interface RecTake { wav: Uint8Array; path: string; seconds: number; transcript: string }
  const av = {
    source: "record" as "record" | "file",
    path: "",
    state: "idle" as "idle" | "counting" | "recording",
    countLeft: 0,
    take: null as RecTake | null,
    previous: null as RecTake | null,
    slot: 1,
    verdict: null as Rec.Verdict | null,
    peak: 0,
    timer: undefined as ReturnType<typeof setInterval> | undefined,
    creating: false,
    playing: false,
  };
  const recorder = host.recorder;
  const transcript = () => (input("av-has-text").checked ? Text.trim(area("av-text").value) : "");
  const noMic = () => host.info.os === "windows"
    ? "Nothing reached the microphone. Allow desktop apps to use it in Windows Settings › Privacy & security › Microphone — or use a file on the other tab."
    : "Nothing reached the microphone. Allow Premiere Pro in System Settings › Privacy & Security › Microphone and restart it — or use a file on the other tab.";
  // A take recorded from given words is sent with them; changed words would
  // make a worse voice from a button that looked safe.
  const takeStale = () => !!av.take && av.take.transcript !== "" && av.take.transcript !== transcript();

  function openAddVoice() {
    host.player.stop();
    Object.assign(av, { source: recorder ? "record" : "file", path: "", state: "idle", take: null, previous: null, verdict: null, creating: false, playing: false });
    input("av-name").value = "";
    input("av-has-text").checked = false;
    area("av-text").value = "";
    input("av-consent").checked = false;
    say("av-file", "No file chosen");
    $("av-file").classList.add("secondary");
    say("av-result", "");
    show("av-tabs", !!recorder);
    if (recorder) void recorder.device().then((name) => say("av-mic", name || "the system default input"));
    refreshAddVoice();
    dlg.showModal();
    // One size for both tabs: the source area holds the taller page.
    const source = $("av-source");
    source.style.minHeight = "";
    let tallest = 0;
    for (const page of recorder ? ["av-page-record", "av-page-file"] : ["av-page-file"]) {
      const was = $(page).hidden;
      $(page).hidden = false;
      tallest = Math.max(tallest, $(page).offsetHeight);
      $(page).hidden = was;
    }
    if (recorder) { show("av-page-record", av.source === "record"); show("av-page-file", av.source === "file"); }
    source.style.minHeight = `${tallest}px`;
  }

  function refreshAddVoice() {
    const recording = av.state !== "idle";
    $("av-tab-record").classList.toggle("active", av.source === "record");
    $("av-tab-file").classList.toggle("active", av.source === "file");
    show("av-page-record", av.source === "record");
    show("av-page-file", av.source === "file");
    // The transcript box is always there (the dialog keeps one size); ticking the box opens it.
    area("av-text").disabled = !input("av-has-text").checked || recording;

    say("av-rec", av.state === "counting" ? `Starting in ${av.countLeft}…` : av.state === "recording" ? "Stop" : av.take ? "Record again" : "Record");
    $("av-rec").title = av.state === "counting" ? "Cancel" : "";
    enable("av-play", !!av.take && !recording);
    enable("av-stop", !!av.take && av.playing);
    $("av-play-glyph").className = av.playing && host.player.state === "playing" ? "g g-pause" : "g g-play";

    // One bar: how far a recording has run, then where playback is in the take.
    const fill = $("av-bar-fill");
    fill.classList.toggle("live", av.state === "recording");
    const barW = fill.parentElement?.clientWidth ?? 0;
    if (av.state === "recording") {
      const s = recorder?.seconds() ?? 0;
      fill.style.width = `${Math.round(Math.min(1, s / REC_LIMIT) * barW)}px`;
      say("av-t-now", Text.formatClock(s));
      say("av-t-total", "−" + Text.formatClock(Math.max(0, REC_LIMIT - s)));
    } else {
      const total = av.take?.seconds ?? REC_LIMIT;
      const at = av.playing ? host.player.position : 0;
      fill.style.width = `${av.take ? Math.round(Math.min(1, at / Math.max(0.01, total)) * barW) : 0}px`;
      say("av-t-now", Text.formatClock(at));
      say("av-t-total", Text.formatClock(total));
    }

    // Guidance before a take, the level while recording, the verdict after.
    let hint = "Speak normally, in the language you want this voice to generate.", role: string | undefined;
    if (av.state === "recording") {
      const n = Rec.levelNote(av.peak);
      hint = n ? n.message : Rec.coach(recorder?.seconds() ?? 0, REC_LIMIT);
      role = n ? n.kind : undefined;
    } else if (av.state === "counting") hint = "Get ready…";
    else if (takeStale()) { hint = "This take was recorded from different words."; role = "warn"; }
    else if (av.verdict?.kind === "error") { hint = av.verdict.message; role = "error"; }
    else if (av.verdict?.clipped) { hint = av.verdict.message; role = "warn"; }
    else if (av.verdict?.good) { hint = av.verdict.message; role = "ok"; }
    say("av-hint", hint, role);

    // Create is live only when it can succeed; the tooltip says what's missing.
    const missing: string[] = [];
    if (!input("av-name").value.trim()) missing.push("a name");
    if (av.source === "record") {
      if (!av.take) missing.push("a recording");
      else if (takeStale() || (av.verdict && !av.verdict.ok)) missing.push("a usable recording");
    } else if (!av.path) missing.push("a file");
    if (input("av-has-text").checked && !transcript()) missing.push("the transcript");
    if (!input("av-consent").checked) missing.push("the permission box");
    enable("av-create", missing.length === 0 && !recording && !av.creating);
    $("av-create").title = missing.length ? "Still needed: " + missing.join(", ") : "";
    enable("av-cancel", !av.creating);
  }

  function stopTimer() { if (av.timer) { clearInterval(av.timer); av.timer = undefined; } }

  async function recStart() {
    if (!recorder) return;
    host.player.stop(); av.playing = false;
    const opened = await recorder.open();
    if (!opened.ok) {
      log.warn("record failed to open", { error: opened.error });
      av.verdict = { ok: false, kind: "error", message: noMic() } as Rec.Verdict;
      refreshAddVoice();
      return;
    }
    log.info("record start");
    av.state = "counting"; av.countLeft = COUNT_IN; av.verdict = null;
    // The take that exists becomes the fallback; the new one goes to the other slot.
    if (av.take) { av.previous = av.take; av.slot = av.slot === 1 ? 2 : 1; }
    av.take = null;
    const t0 = Date.now();
    stopTimer();
    av.timer = setInterval(() => {
      if (av.state === "counting") {
        const left = COUNT_IN - Math.floor((Date.now() - t0) / 1000);
        if (left <= 0) { av.state = "recording"; recorder.begin(); }
        else av.countLeft = left;
      } else if (av.state === "recording") {
        av.peak = recorder.level();
        if (recorder.seconds() >= REC_LIMIT) { void recStop(); return; }
      }
      refreshAddVoice();
    }, 100);
    refreshAddVoice();
  }

  async function recStop() {
    if (!recorder) return;
    stopTimer();
    if (av.state === "counting") {
      // Cancelled before it began: the previous take comes back.
      recorder.cancel(); av.state = "idle"; av.take = av.previous; refreshAddVoice();
      return;
    }
    av.state = "idle";
    const pcm = await recorder.stop();
    const stats = pcm ? Wav.pcmStats(pcm) : null;
    const made = pcm ? Wav.pcmToWav(pcm) : null;
    if (!pcm || !stats || !made || stats.seconds <= 0) {
      av.verdict = { ok: false, kind: "error", message: noMic() } as Rec.Verdict;
      av.take = av.previous;
      refreshAddVoice();
      return;
    }
    const path = files.join(files.dataDir, "tmp", `take_${av.slot}.wav`);
    await files.write(path, made.wav);
    av.verdict = Rec.judge(stats, transcript());
    av.take = av.verdict.silent ? null : { wav: made.wav, path, seconds: stats.seconds, transcript: transcript() };
    if (av.verdict.silent) av.verdict = { ok: false, kind: "error", message: noMic() } as Rec.Verdict;
    log.metric("record.take", { seconds: stats.seconds, peak: stats.peak, rms: stats.rms, hot_pct: stats.hot_ratio * 100, verdict: av.verdict.kind });
    refreshAddVoice();
  }

  on("av-rec", "click", () => { if (av.state === "idle") void recStart(); else void recStop(); });
  on("av-play", "click", () => {
    if (!av.take) return;
    if (av.playing && host.player.state === "playing") { host.player.pause(); refreshAddVoice(); return; }
    if (!av.playing) host.player.load(av.take.path, av.take.seconds);
    av.playing = true;
    host.player.play();
    refreshAddVoice();
  });
  on("av-stop", "click", () => { host.player.stop(); av.playing = false; refreshAddVoice(); });
  host.player.onChange(() => {
    if (!dlg.open || !av.playing) return;
    if (host.player.state === "stopped") av.playing = false;
    refreshAddVoice();
  });
  // Switching tabs mid-take stops and keeps; nothing carries over between tabs.
  const switchTo = (source: "record" | "file") => () => {
    if (av.state !== "idle") void recStop();
    host.player.stop(); av.playing = false;
    av.source = source;
    refreshAddVoice();
  };
  on("av-tab-record", "click", switchTo("record"));
  on("av-tab-file", "click", switchTo("file"));

  on("av-pick", "click", async () => {
    const path = await files.pickOpen(["wav", "mp3", "flac", "aac", "opus", "m4a"]);
    if (!path) return;
    const size = await files.size(path);
    if (size !== null && size > Boson.REF_MAX_BYTES) { say("av-result", `That file is ${(size / 1048576).toFixed(1)} MB; the limit is 10 MB.`, "error"); return; }
    av.path = path;
    say("av-file", files.basename(path));
    $("av-file").classList.remove("secondary");
    say("av-result", "");
    refreshAddVoice();
  });
  for (const id of ["av-name", "av-text"]) on(id, "input", refreshAddVoice);
  for (const id of ["av-consent", "av-has-text"]) on(id, "change", refreshAddVoice);
  on("av-cancel", "click", () => {
    stopTimer();
    if (av.state !== "idle") recorder?.cancel();
    av.state = "idle";
    host.player.stop();
    dlg.close();
    loadTake();
  });
  on("av-create", "click", async () => {
    const name = input("av-name").value.trim();
    const audio = av.source === "record" ? av.take?.wav ?? null : await files.read(av.path);
    if (!audio) { say("av-result", "Could not read that file.", "error"); return; }
    av.creating = true;
    refreshAddVoice();
    say("av-result", "Creating the voice…");
    const res = await client.createVoice(name, audio, transcript());
    av.creating = false;
    log.metric("voice.create", { ok: res.ok ? 1 : 0, source: av.source, code: res.code ?? "" });
    if (!res.ok || !res.id) { say("av-result", res.error ?? "Couldn't create the voice.", "error"); refreshAddVoice(); return; }
    cfg().voices = [...(cfg().voices ?? []).filter((v) => v.id !== res.id), { id: res.id, name, created: Math.floor(Date.now() / 1000) }];
    await store.save();
    host.player.stop();
    dlg.close();
    loadTake();
    st.pickedVoice = res.id;
    renderVoices();
    note(`Created “${name}”. It's in your voice list.`, "ok");
  });

  // ------------------------------------------------------------- start

  input("auto-place").checked = cfg().auto_place === true;
  input("auto-subs").checked = cfg().auto_subtitles === true;
  input("auto-preview").checked = cfg().auto_preview !== false;
  input("preview-subs").checked = cfg().manual_subtitles === true;
  st.pickedVoice = currentVoice();
  refreshChip();
  renderVoices();
  renderTags();
  route("generate");
  refreshUpdate();
  void followProject();
  // Once a day at most, unless the last check found something.
  const day = 24 * 3600;
  if (cfg().check_updates !== false && (cfg().update_state === "available" || Date.now() / 1000 - (cfg().last_update_check || 0) > day)) {
    void checkUpdates(true);
  }
  log.info("panel ready", { voices: voiceEntries().length, key: store.key ? 1 : 0 });
}
