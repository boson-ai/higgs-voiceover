// Package the CEP build as a signed extension:
//   dist/Higgs-VoiceOver-<version>-Premiere-Pro.zxp
//
//   ZXPSIGNCMD=/path/to/ZXPSignCmd ZXP_CERT=/path/to/cert.p12 ZXP_PASSWORD_FILE=/path/to/password \
//     npm run package:cep
//
// ZXPSignCmd is Adobe's (github.com/Adobe-CEP/CEP-Resources, ZXPSignCMD). A
// self-signed certificate is accepted for extensions distributed outside the
// Adobe Marketplace; the signature is timestamped so it stays valid after the
// certificate expires. Without a signature Premiere loads the panel only with
// PlayerDebugMode on (development).

import { execFileSync } from "node:child_process";
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const version = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version;
const need = (name) => { const v = process.env[name]; if (!v) { console.error(`set ${name} (see the top of this file)`); process.exit(2); } return v; };
const tool = need("ZXPSIGNCMD"), cert = need("ZXP_CERT"), password = readFileSync(need("ZXP_PASSWORD_FILE"), "utf8").trim();

execFileSync("node", [join(root, "scripts/build.mjs"), "--cep"], { stdio: "inherit" });
const build = join(root, "build-cep");

// What goes in must be exactly the extension: no dev files, no ._ or
// .DS_Store from this drive, no symlinks (they break the signature check).
const bad = [];
const walk = (d) => {
  for (const n of readdirSync(d)) {
    const p = join(d, n);
    if (lstatSync(p).isSymbolicLink() || n.startsWith("._") || n === ".DS_Store" || n === ".debug") bad.push(p);
    else if (lstatSync(p).isDirectory()) walk(p);
  }
};
walk(build);
for (const p of bad) rmSync(p, { recursive: true, force: true });

const out = join(root, "dist", `Higgs-VoiceOver-${version}-Premiere-Pro.zxp`);
mkdirSync(dirname(out), { recursive: true });
if (existsSync(out)) rmSync(out);
execFileSync(tool, ["-sign", build, out, cert, password, "-tsa", "http://timestamp.digicert.com"], { stdio: "inherit" });
const verify = execFileSync(tool, ["-verify", out, "-certInfo", "-skipOnlineRevocationChecks"], { encoding: "utf8" });
if (!/Signature verified successfully/i.test(verify)) { console.error(verify); process.exit(1); }
console.log(`signed ${out}`);
