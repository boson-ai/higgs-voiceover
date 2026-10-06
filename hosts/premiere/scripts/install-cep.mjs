// Install the CEP build for this user, unsigned, for development:
//   npm run install:cep
// Builds build-cep/, copies it to the per-user CEP extensions folder, and
// turns on PlayerDebugMode (Adobe's switch for loading unsigned panels).
// Restart Premiere, then Window › Extensions › Higgs VoiceOver.
// A .debug file opens DevTools for the panel at http://localhost:8088.

import { execFileSync } from "node:child_process";
import { cpSync, mkdirSync, rmSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { homedir, platform } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const ID = "ai.boson.higgs-voiceover.cep";
execFileSync("node", [join(root, "scripts/build.mjs"), "--cep"], { stdio: "inherit" });

const win = platform() === "win32";
const base = win ? join(process.env.APPDATA ?? "", "Adobe", "CEP", "extensions")
                 : join(homedir(), "Library", "Application Support", "Adobe", "CEP", "extensions");
const dest = join(base, ID);
mkdirSync(base, { recursive: true });
rmSync(dest, { recursive: true, force: true });
cpSync(join(root, "build-cep"), dest, { recursive: true });

// The repository's drive keeps extended attributes as ._ files; none belong here.
const sweep = (d) => { for (const n of readdirSync(d)) { const p = join(d, n); if (n.startsWith("._")) rmSync(p); else if (statSync(p).isDirectory()) sweep(p); } };
sweep(dest);

writeFileSync(join(dest, ".debug"), `<?xml version="1.0" encoding="UTF-8"?>
<ExtensionList>
  <Extension Id="${ID}.panel">
    <HostList><Host Name="PPRO" Port="8088"/></HostList>
  </Extension>
</ExtensionList>
`);

// CSXS.12 = Premiere 25 and later; CSXS.11 = Premiere 22–24.
for (const v of ["11", "12"]) {
  if (win) execFileSync("reg", ["add", `HKCU\\Software\\Adobe\\CSXS.${v}`, "/v", "PlayerDebugMode", "/t", "REG_SZ", "/d", "1", "/f"], { stdio: "ignore" });
  else execFileSync("defaults", ["write", `com.adobe.CSXS.${v}`, "PlayerDebugMode", "1"]);
}
console.log(`installed ${dest}\nrestart Premiere, then Window › Extensions › Higgs VoiceOver`);
