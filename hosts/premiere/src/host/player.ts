// The audio preview's transport. UXP has no <audio> and no Web Audio; since
// UXP 9.1 a <video> element plays audio files, which is what this uses. The
// browser preview passes its own element and URL scheme.

import type { Player, PlayerState } from "./host.ts";

export function createMediaPlayer(el: HTMLVideoElement, urlFor: (path: string) => string): Player {
  let state: PlayerState = "empty";
  let known = 0;          // the take's length as we measured it; the element's may be NaN until loaded
  const listeners: (() => void)[] = [];
  let ticker: ReturnType<typeof setInterval> | undefined;

  const emit = () => listeners.forEach((cb) => cb());
  const setState = (s: PlayerState) => {
    state = s;
    if (s === "playing" && !ticker) ticker = setInterval(emit, 100);
    if (s !== "playing" && ticker) { clearInterval(ticker); ticker = undefined; }
    emit();
  };

  el.addEventListener("ended", () => { el.pause(); safeSeek(0); setState("stopped"); });
  el.addEventListener("error", () => setState("stopped"));
  el.addEventListener("timeupdate", emit);

  function safeSeek(s: number) {
    try { el.currentTime = s; } catch { /* not loaded yet */ }
  }

  return {
    get state() { return state; },
    get position() { return Number.isFinite(el.currentTime) ? el.currentTime : 0; },
    get duration() { return Number.isFinite(el.duration) && el.duration > 0 ? el.duration : known; },
    load(path, seconds) {
      el.pause();
      known = seconds;
      el.src = urlFor(path);
      safeSeek(0);
      setState("stopped");
    },
    play() {
      if (state === "empty") return;
      const p = el.play() as unknown;
      if (p && typeof (p as Promise<void>).catch === "function") (p as Promise<void>).catch(() => setState("stopped"));
      setState("playing");
    },
    pause() {
      if (state !== "playing") return;
      el.pause();
      setState("paused");
    },
    stop() {
      if (state === "empty") return;
      el.pause();
      safeSeek(0);
      setState("stopped");
    },
    seek(s) {
      safeSeek(Math.max(0, Math.min(s, this.duration || s)));
      emit();
    },
    onChange(cb) { listeners.push(cb); },
  };
}

/** A native path as a file: URL (spaces and non-ASCII escaped, Windows drive kept). */
export function fileUrl(path: string): string {
  const p = path.replace(/\\/g, "/");
  return "file://" + (p.startsWith("/") ? "" : "/") + p.split("/").map(encodeURIComponent).join("/").replace(/^\/([A-Za-z])%3A/, "/$1:");
}
