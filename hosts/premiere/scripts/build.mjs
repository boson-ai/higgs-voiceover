// Build what Premiere loads, or the browser preview.
//
//   npm run build            build/      the UXP plugin (UXP Developer Tool: Load build/)
//   npm run build:cep        build-cep/  the CEP extension folder
//   npm run build -- --watch rebuild on change
//   npm run preview          build-preview/ (stand-ins for Premiere, see preview/) and a local server

import * as esbuild from "esbuild";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const preview = process.argv.includes("--preview");
const cep = process.argv.includes("--cep");
const watch = process.argv.includes("--watch");
const out = join(root, preview ? "build-preview" : cep ? "build-cep" : "build");
const version = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version;

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

function copyStatic() {
  // The preview gets a viewport tag so a narrow browser window behaves like a narrow panel.
  const html = readFileSync(join(root, "src/ui/index.html"), "utf8");
  writeFileSync(join(out, "index.html"), preview ? html.replace("<head>", '<head>\n  <meta name="viewport" content="width=device-width">\n  <meta name="color-scheme" content="dark light">') : html);
  cpSync(join(root, "src/ui/styles.css"), join(out, "styles.css"));
  if (cep) {
    mkdirSync(join(out, "CSXS"), { recursive: true });
    writeFileSync(join(out, "CSXS/manifest.xml"), readFileSync(join(root, "cep/CSXS/manifest.xml"), "utf8").replaceAll("__VERSION__", version));
    cpSync(join(root, "cep/jsx"), join(out, "jsx"), { recursive: true });
    cpSync(join(root, "icons"), join(out, "icons"), { recursive: true });
  } else if (!preview) {
    writeFileSync(join(out, "manifest.json"), readFileSync(join(root, "manifest.json"), "utf8").replace("__VERSION__", version));
    cpSync(join(root, "icons"), join(out, "icons"), { recursive: true });
  }
}

const options = {
  entryPoints: [join(root, preview ? "preview/main.ts" : cep ? "src/main-cep.ts" : "src/main.ts")],
  outfile: join(out, "main.js"),
  bundle: true,
  // UXP loads CommonJS and provides its modules; CEP's Chromium runs a
  // script whose require() is Node's (mixed context).
  format: preview || cep ? "iife" : "cjs",
  platform: preview ? "browser" : "neutral",
  external: preview ? [] : cep ? ["fs", "path", "os", "https", "child_process"] : ["uxp", "premierepro", "fs", "os"],
  target: "es2022",
  sourcemap: preview ? "inline" : false,
  define: { __VERSION__: JSON.stringify(preview ? version + "-preview" : version), ...(cep ? { "process.env.NODE_ENV": '"production"' } : {}) },
  logLevel: "warning",
  plugins: [{ name: "static", setup(b) { b.onEnd(copyStatic); } }],
};

if (watch) {
  const ctx = await esbuild.context(options);
  await ctx.watch();
  console.log(`watching — ${out}`);
} else {
  await esbuild.build(options);
  console.log(`built ${preview ? "preview" : "plugin"} ${version} → ${out}`);
}
