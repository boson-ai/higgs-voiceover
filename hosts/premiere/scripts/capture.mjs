// Screenshot a preview state with headless Chrome — the visual check for
// layout, colours and hover states without Premiere. Needs `npm run preview`
// running, and Google Chrome (a throwaway profile; your own is not touched).
//
//   node scripts/capture.mjs <out.png> "<query>" [width] [height]
//   node scripts/capture.mjs /tmp/gen.png "state=done&theme=light&hover=generate,place-all" 980 680
//
// Query: state=setup|empty|text|done|placed|settings|addvoice, theme=darkest|dark|light,
// host=cep|uxp, hover=<id>,<id> (drawn as hovered), tab=file, record=take, dirty=1.

import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [out, query = "state=done", width = "980", height = "680"] = process.argv.slice(2);
if (!out) { console.error("usage: node scripts/capture.mjs <out.png> \"<query>\" [width] [height]"); process.exit(2); }

const CHROME = process.env.CHROME ?? (process.platform === "win32"
  ? "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"
  : "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome");
const profile = mkdtempSync(join(tmpdir(), "higgs-capture-"));
rmSync(out, { force: true });

// Headless Chrome writes the file and then lingers; wait for the file, then stop it.
const chrome = spawn(CHROME, [
  "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run",
  `--user-data-dir=${profile}`, `--window-size=${width},${height}`, "--force-device-scale-factor=2",
  "--virtual-time-budget=12000", `--screenshot=${out}`, `http://localhost:${process.env.PORT ?? 5178}/?${query}`,
], { stdio: "ignore" });

const until = Date.now() + 30_000;
while (Date.now() < until && !(existsSync(out) && statSync(out).size > 0)) await new Promise((r) => setTimeout(r, 300));
await new Promise((r) => setTimeout(r, 400));
chrome.kill();
rmSync(profile, { recursive: true, force: true });
if (!existsSync(out)) { console.error("no screenshot — is `npm run preview` running?"); process.exit(1); }
console.log(out);
