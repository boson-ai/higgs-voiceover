// Package build/ as an installable .ccx (a zip of the plugin folder):
//   dist/Higgs-VoiceOver-<version>-Premiere-Pro.ccx
// One package covers macOS and Windows. Opening it hands it to Creative Cloud,
// which installs it; `UnifiedPluginInstallerAgent --install <file>` does the same.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const version = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version;
execFileSync("node", [join(root, "scripts/build.mjs")], { stdio: "inherit" });

const dist = join(root, "dist");
mkdirSync(dist, { recursive: true });
const out = join(dist, `Higgs-VoiceOver-${version}-Premiere-Pro.ccx`);
if (existsSync(out)) rmSync(out);
// The repository's drive keeps extended attributes as ._ files; neither
// they nor Finder's .DS_Store belong in the package.
execFileSync("zip", ["-r", "-X", "-q", out, ".", "-x", "*.DS_Store", "-x", "._*", "-x", "*/._*"], {
  cwd: join(root, "build"),
  env: { ...process.env, COPYFILE_DISABLE: "1" },
});
console.log(`packaged ${out}`);
