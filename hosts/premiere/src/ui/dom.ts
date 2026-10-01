// Small DOM helpers. The panel is plain HTML; these keep the wiring short.

export function $(id: string): HTMLElement {
  const el = document.getElementById(id);
  if (!el) throw new Error(`#${id} is missing from index.html`);
  return el;
}
export const input = (id: string) => $(id) as HTMLInputElement;
export const area = (id: string) => $(id) as HTMLTextAreaElement;
export const select = (id: string) => $(id) as HTMLSelectElement;
export const button = (id: string) => $(id) as HTMLButtonElement;

export function on(id: string, event: string, handler: (e: Event) => void): void {
  $(id).addEventListener(event, handler);
}

export function show(id: string, visible: boolean): void {
  $(id).hidden = !visible;
}

export function enable(id: string, enabled: boolean): void {
  (($(id) as HTMLButtonElement).disabled) = !enabled;
}

/** Text with an optional colour role: "ok" | "warn" | "error" | "secondary" | "faint". */
export function say(id: string, text: string, role?: string): void {
  const el = $(id);
  el.textContent = text;
  for (const r of ["ok-text", "warn-text", "error-text"]) el.classList.remove(r);
  if (role === "ok" || role === "warn" || role === "error") el.classList.add(role + "-text");
}

export function el(tag: string, cls?: string, text?: string): HTMLElement {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

/**
 * A `<select>`'s value. UXP needs every option to carry `value`, and setting
 * `.value` does not show the choice — the option's `selected` must be set.
 */
export function setChoice(id: string, value: string): void {
  const s = select(id);
  for (const o of Array.from(s.options)) {
    if (o.value === value) o.setAttribute("selected", "");
    else o.removeAttribute("selected");
  }
  s.value = value;
}
