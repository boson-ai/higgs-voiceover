// End-to-end check of the installed CEP panel inside a running Premiere.
//
//   npm run install:cep, open Premiere on a scratch project with a sequence,
//   open Window › Extensions › Higgs VoiceOver, then:  node tests/e2e-premiere.mjs
//
// Drives the panel's own controls through its DevTools port (the .debug file
// install:cep writes) and reads the timeline back with ExtendScript. It adds
// clips and captions, locks and unlocks A1 and moves the playhead — use a
// scratch project. Makes a handful of real Boson requests on the saved key.
// Not part of `npm test`.
const list = await (await fetch("http://localhost:8088/json")).json();
const ws = new WebSocket(list[0].webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r));
let id = 0; const pending = new Map(); const errors = [];
ws.addEventListener("message", (m) => {
  const d = JSON.parse(m.data);
  if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); }
  if (d.method === "Runtime.exceptionThrown") errors.push(d.params.exceptionDetails.exception?.description ?? d.params.exceptionDetails.text);
  if (d.method === "Runtime.consoleAPICalled" && d.params.type === "error") errors.push(d.params.args.map((a) => a.value ?? a.description).join(" "));
});
const send = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
const js = async (expr) => { const d = await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true }); if (d.result?.exceptionDetails) throw new Error(d.result.exceptionDetails.exception?.description); return d.result?.result?.value; };
const jsx = (code) => js(`new Promise((r) => window.__adobe_cep__.evalScript(${JSON.stringify(code)}, r))`);
await send("Runtime.enable");
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];
const check = (name, ok, detail = "") => { results.push([ok ? "PASS" : "FAIL", name, detail]); console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  — " + detail : ""}`); };

// --- panel helpers (in the panel's page)
const click = (elId) => js(`document.getElementById(${JSON.stringify(elId)}).click()`);
const status = () => js(`document.getElementById("status").textContent`);
const setText = (t) => js(`(() => { const b = document.getElementById("text"); b.value = ${JSON.stringify(t)}; b.dispatchEvent(new Event("input")); })()`);
const checkbox = (elId, on) => js(`(() => { const c = document.getElementById(${JSON.stringify(elId)}); if (c.checked !== ${on}) c.click(); return c.checked; })()`);
async function idle(timeout = 60000) {
  const t0 = Date.now();
  await wait(400);
  while (Date.now() - t0 < timeout) {
    if (await js(`document.getElementById("stop").disabled`)) return true;
    await wait(300);
  }
  return false;
}
const tracksDump = () => jsx(`(function(){var s=app.project.activeSequence,o=[];for(var i=0;i<s.audioTracks.numTracks;i++){var t=s.audioTracks[i],c=[];for(var j=0;j<t.clips.numItems;j++)c.push(Math.round(t.clips[j].start.seconds*100)/100+"-"+Math.round(t.clips[j].end.seconds*100)/100);o.push("A"+(i+1)+":"+c.join(","));}return o.join(" | ");})()`);
const clipsOn = async (n) => JSON.parse(await jsx(`(function(){var t=app.project.activeSequence.audioTracks[${n - 1}],c=[];for(var j=0;j<t.clips.numItems;j++)c.push([t.clips[j].start.seconds,t.clips[j].end.seconds,t.clips[j].name]);return hvJson(c);})()`));
const setPlayhead = (sec) => jsx(`app.project.activeSequence.setPlayerPosition(String(Math.round(${sec}*254016000000)))`);
const audioCount = async () => Number(await jsx(`app.project.activeSequence.audioTracks.numTracks`));

// --- 0. where we are
const info = JSON.parse(await jsx(`HiggsVO.info()`));
console.log("project:", info.project, "· sequence open:", info.hasSequence);
if (!info.hasSequence) { console.log("Open a sequence first."); process.exit(1); }
const cfgBefore = await js(`JSON.stringify({ auto_place: document.getElementById("auto-place").checked, auto_subs: document.getElementById("auto-subs").checked, auto_preview: document.getElementById("auto-preview").checked, preview_subs: document.getElementById("preview-subs").checked })`);
console.log("panel boxes before:", cfgBefore, "\ntracks before:", await tracksDump());
await click("tab-generate");
await checkbox("auto-preview", false);

// --- 1. one line, placed automatically on the last track at the playhead
const n0 = await audioCount();
await setPlayhead(20);
await checkbox("auto-place", true); await checkbox("auto-subs", false);
await setText("This is the first end to end test line.");
await click("generate");
check("generate one line finishes", await idle());
let st = await status();
check("auto-placed message names the last track", st.startsWith(`Placed on A${n0} `), st);
let clips = await clipsOn(n0);
const first = clips.find((c) => Math.abs(c[0] - 20) < 0.05) ?? clips.at(-1);
check("clip sits on the last track at/after the playhead", !!first && first[0] >= 19.95, JSON.stringify(first));

// --- 2. two lines → back to back, after the clip now at the playhead
await setText("Second test line.\nThird test line.");
await click("generate");
check("generate two lines finishes", await idle());
st = await status();
check("two clips placed after the clip at the playhead", /^Placed 2 clips on A\d+, starting after the clip at the playhead\.$/.test(st), st);
clips = (await clipsOn(n0)).sort((a, b) => a[0] - b[0]);
const tail = clips.slice(-3);
const gapless = tail.length === 3 && Math.abs(tail[1][0] - tail[0][1]) < 0.05 && Math.abs(tail[2][0] - tail[1][1]) < 0.05;
check("the three clips are back to back, no overlap", gapless, JSON.stringify(tail.map((c) => [c[0].toFixed(2), c[1].toFixed(2)])));

// --- 3. Place all by hand with subtitles → native captions
await checkbox("auto-place", false); await checkbox("preview-subs", true);
await setText("Hello dear John, welcome back to the channel.");
await click("generate");
check("generate a timed line finishes", await idle());
await setPlayhead(60);
await click("place-all");
await wait(2500);
st = await status();
check("placed with native captions", /, with subtitles\.$/.test(st), st);
const srtInBin = await jsx(`(function(){var r=app.project.rootItem,n=0;for(var i=0;i<r.children.numItems;i++){var b=r.children[i];if(b.type===2&&b.name==="Higgs VoiceOver")for(var j=0;j<b.children.numItems;j++)if(/\\.srt$/i.test(b.children[j].name))n++;}return n;})()`);
check("the .srt is in the Higgs VoiceOver bin", Number(srtInBin) >= 1, `${srtInBin} file(s)`);

// --- 4. a chosen track (A1), then a locked one, then one the sequence lacks
async function chooseTrack(value) {
  await click("tab-settings"); await wait(400);
  await js(`(() => { const s = document.getElementById("set-track"); s.value = ${JSON.stringify(value)}; s.dispatchEvent(new Event("change")); })()`);
  await click("set-save"); await wait(400); await click("tab-generate");
}
await checkbox("preview-subs", false);
await chooseTrack("A1");
await setPlayhead(90);
await click("place-all"); await wait(2000);
st = await status();
check("placing on a chosen track says A1", st.startsWith("Placed on A1"), st);
await jsx(`app.project.activeSequence.audioTracks[0].setLocked(1)`);
await setPlayhead(120);
await click("place-all"); await wait(2000);
st = await status();
check("a locked track is refused with what to do", st === "A1 is locked. Unlock it and place again.", st);
await jsx(`app.project.activeSequence.audioTracks[0].setLocked(0)`);
await click("tab-settings"); await wait(400);
await js(`(() => { const s = document.getElementById("set-track"); const o = document.createElement("option"); o.value = "A9"; o.textContent = "A9"; s.appendChild(o); s.value = "A9"; s.dispatchEvent(new Event("change")); })()`);
await click("set-save"); await wait(300); await click("tab-generate");
await click("place-all"); await wait(1500);
st = await status();
check("a track the sequence lacks is refused", st === "This sequence has no A9 track. Choose another track in Settings.", st);
await click("tab-settings"); await wait(300); await click("set-reset"); await click("set-save"); await wait(300); await click("tab-generate");
check("Reset to default puts the track back to the last one", (await js(`(() => { document.getElementById("tab-settings").click(); const v = document.getElementById("set-track").value; document.getElementById("tab-generate").click(); return v; })()`)) === `A${await audioCount()}`);

// --- 5. Stop mid-run keeps what was made
await setText("Stop test one.\nStop test two.\nStop test three.");
await click("generate");
await wait(2200);
await click("stop");
await wait(500);
st = await status();
check("Stop keeps what was generated", /^Stopped — \d of 3 generated$|^Stopped$/.test(st), st);

// --- 6. over the 5,000-character limit
await setText("a ".repeat(2600));
st = await status();
const genDisabled = await js(`document.getElementById("generate").disabled`);
check("an over-limit line blocks Generate and says so", genDisabled && /5,000-character limit/.test(st), st);
await setText("");

// --- 7. a voice sample does not touch the preview card
const cardBefore = await js(`document.getElementById("take-name").textContent`);
await js(`(() => { const r = [...document.querySelectorAll("#voice-list .item")].find((x) => x.textContent.includes("Oliver")); r.click(); })()`);
await click("voice-preview");
await wait(4000);
const cardAfter = await js(`document.getElementById("take-name").textContent`);
check("voice preview leaves the preview card alone", cardBefore === cardAfter, cardAfter);
await wait(4000);
check("Preview button comes back after the sample", (await js(`document.getElementById("voice-preview").textContent`)) === "Preview");

// --- 8. Settings: connection and update check
await click("tab-settings"); await wait(300);
await click("set-test"); await wait(2500);
check("Test connection says Connected", /Connected/.test(await js(`document.getElementById("set-key-result").textContent`)));
await click("set-check"); await wait(3000);
check("update check answers (not 'GitHub is busy')", /Up to date|available/.test(await js(`document.getElementById("set-update-status").textContent`)), await js(`document.getElementById("set-update-status").textContent`));
await click("tab-generate");

// --- restore the panel's boxes as they were
const b = JSON.parse(cfgBefore);
await checkbox("auto-place", b.auto_place); await checkbox("auto-subs", b.auto_subs); await checkbox("auto-preview", b.auto_preview); await checkbox("preview-subs", b.preview_subs);

console.log("\ntracks after:", await tracksDump());
check("no script errors in the panel during the run", errors.length === 0, errors.slice(0, 3).join(" / "));
const failed = results.filter((r) => r[0] === "FAIL").length;
console.log(`\n${results.length - failed}/${results.length} passed`);
ws.close();
