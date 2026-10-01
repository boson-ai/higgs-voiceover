// UXP draws a subset of CSS and ignores the rest without a word, which shows
// up only as a broken layout inside Premiere. This holds the stylesheet to
// the properties Adobe documents (uxp-api/reference-css) so the browser
// preview cannot drift into features the panel will never get.

import { readFileSync } from "node:fs";

const FILE = new URL("../src/ui/styles.css", import.meta.url);

// developer.adobe.com/premiere-pro/uxp/uxp-api/reference-css/styles, plus
// position/z-index which the known-issues page confirms.
const ALLOWED = new Set(`align-content align-items align-self background-attachment background-color
background-image background-repeat background-size background border-bottom-color
border-bottom-left-radius border-bottom-right-radius border-bottom-style border-bottom-width
border-bottom border-color border-left-color border-left-style border-left-width border-left
border-radius border-right-color border-right-style border-right-width border-right border-style
border-top-color border-top-left-radius border-top-right-radius border-top-style border-top-width
border-top border-width border bottom color display flex-basis flex-direction flex-grow
flex-shrink flex-wrap flex font-family font-size font-style font-weight height
justify-content left letter-spacing margin-bottom margin-left margin-right margin-top margin
max-height max-width min-height min-width opacity overflow-x overflow-y overflow
padding-bottom padding-left padding-right padding-top padding right text-align
text-overflow top visibility white-space width position z-index`.split(/\s+/));

// Called out by name in Adobe's known issues, with the alternative.
const WHY = {
  gap: "not supported — use margins on the children",
  "row-gap": "not supported — use margins",
  "column-gap": "not supported — use margins",
  "line-height": "not documented — set height or padding",
  transition: "transitions are not supported",
  animation: "animations are not supported",
  "text-transform": "not supported — write the text in the case wanted",
  font: "the font shorthand is not supported — use font-size/font-weight/font-family",
  "box-shadow": "not supported — use a border",
  "grid-template-columns": "grid is not supported in Premiere — use flex",
  order: "not documented — use flex-direction: *-reverse",
};

const src = readFileSync(FILE, "utf8").replace(/\/\*[\s\S]*?\*\//g, (c) => c.replace(/[^\n]/g, " "));
const problems = [];
const lineOf = (i) => src.slice(0, i).split("\n").length;

for (const m of src.matchAll(/@keyframes|display\s*:\s*grid/g)) problems.push(`${lineOf(m.index)}: ${m[0]} — grid and keyframes are not supported`);

// Declarations are what sits between braces; selectors are left alone.
for (const block of src.matchAll(/\{([^{}]*)\}/g)) {
  let at = block.index + 1;
  for (const decl of block[1].split(";")) {
    const colon = decl.indexOf(":");
    if (colon > 0) {
      const prop = decl.slice(0, colon).trim();
      const value = decl.slice(colon + 1);
      const where = lineOf(at + decl.indexOf(prop));
      if (!prop.startsWith("--")) {
        if (!ALLOWED.has(prop)) problems.push(`${where}: ${prop} — ${WHY[prop] ?? "not in UXP's supported properties"}`);
        if (/\d%/.test(value)) problems.push(`${where}: ${prop}:${value.trim()} — % is not in UXP's unit list`);
      }
    }
    at += decl.length + 1;
  }
}

if (problems.length) {
  console.error(`styles.css uses CSS that UXP does not draw:\n  ${problems.join("\n  ")}`);
  process.exit(1);
}
console.log(`styles.css: ok (${lineOf(src.length)} lines, UXP-supported properties only)`);
