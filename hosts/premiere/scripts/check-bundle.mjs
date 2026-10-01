// UXP is not Node and not a browser: the plugin bundle may only require the
// modules Premiere provides, and must not lean on globals UXP lacks. A slip
// here passes every test in Node and fails only inside Premiere.

import { readFileSync } from "node:fs";

const src = readFileSync(new URL("../build/main.js", import.meta.url), "utf8");
const problems = [];
for (const m of src.matchAll(/require\("([^"]+)"\)/g)) {
  if (!["uxp", "premierepro", "fs", "os"].includes(m[1])) problems.push(`requires "${m[1]}", which UXP does not provide`);
}
const MISSING = {
  "TextDecoder": "UXP has no TextDecoder (core/base64.ts has utf8Decode)",
  "TextEncoder": "UXP has no TextEncoder (core/base64.ts has utf8Encode)",
  "Buffer.": "Buffer is Node's",
  "process.": "process is Node's",
  "Intl.Segmenter": "not confirmed in UXP",
  "localStorage": "keep state in the data folder, not localStorage",
  "AudioContext": "UXP has no Web Audio",
  "getUserMedia": "UXP has no microphone access",
};
for (const [needle, why] of Object.entries(MISSING)) if (src.includes(needle)) problems.push(`uses ${needle.replace(/\.$/, "")}: ${why}`);
if (problems.length) {
  console.error("build/main.js:\n  " + [...new Set(problems)].join("\n  "));
  process.exit(1);
}
console.log("build/main.js: only UXP modules and globals");
