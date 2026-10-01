// Tags coloured by type inside the text box, as in the Resolve build.
//
// Where the panel is Chromium (the CEP build, the browser preview) the
// textarea's own text is made transparent and a mirror underneath draws the
// same text with each <|…|> token coloured; the textarea keeps the caret,
// selection, undo and input methods. UXP cannot do this (a text field draws
// above everything and has no rich text), so there the box stays plain.

const KIND_CLASS: [RegExp, string][] = [
  [/^emotion:/, "k-emotion"],
  [/^style:/, "k-style"],
  [/^prosody:speed_/, "k-speed"],
  [/^prosody:pitch_/, "k-pitch"],
  [/^prosody:expressive_/, "k-expressive"],
  [/^prosody:/, "k-pause"],
  [/^sfx:/, "k-sfx"],
];

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** The text as HTML, each tag in its type's colour. */
export function taggedHtml(text: string): string {
  let out = "", at = 0;
  for (const m of text.matchAll(/<\|([^|>]*)\|>/g)) {
    out += esc(text.slice(at, m.index));
    const cls = KIND_CLASS.find(([re]) => re.test(m[1]))?.[1] ?? "k-other";
    out += `<span class="${cls}">${esc(m[0])}</span>`;
    at = (m.index ?? 0) + m[0].length;
  }
  // A trailing line break needs something after it or the mirror is a line short.
  return out + esc(text.slice(at)) + "​";
}

export interface Highlighter { paint(): void }

export function attachHighlighter(box: HTMLTextAreaElement, mirror: HTMLElement, frame: HTMLElement): Highlighter {
  frame.classList.add("highlight");
  let last = "\u0000";
  const fit = () => {
    // Wrap at the same width as the textarea, whose scrollbar takes room.
    const gutter = box.offsetWidth - box.clientWidth;
    mirror.style.borderRightWidth = `${Math.max(1, gutter)}px`;
    mirror.scrollTop = box.scrollTop;
  };
  const paint = () => {
    if (box.value !== last) { last = box.value; mirror.innerHTML = taggedHtml(last); }
    fit();
  };
  box.addEventListener("scroll", () => { mirror.scrollTop = box.scrollTop; });
  box.addEventListener("input", paint);
  window.addEventListener("resize", fit);
  paint();
  return { paint };
}
