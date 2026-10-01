// Base64 and UTF-8, by hand: UXP has neither TextEncoder/TextDecoder nor a
// dependable atob/btoa, and a voice reference is binary that has to travel
// inside a JSON body. Port of b64_encode / b64_decode in
// hosts/resolve/src/higgs/util.lua.

const B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

const B64_VALUES: Int16Array = (() => {
  const t = new Int16Array(128).fill(-1);
  for (let i = 0; i < B64_CHARS.length; i++) t[B64_CHARS.charCodeAt(i)] = i;
  return t;
})();

/** Base64-encode bytes (used for voice-clone reference audio). */
export function b64Encode(data: Uint8Array): string {
  const len = data.length;
  const out: string[] = [];
  let i = 0;
  for (; i + 2 < len; i += 3) {
    const n = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
    out.push(B64_CHARS[(n >> 18) & 63] + B64_CHARS[(n >> 12) & 63] + B64_CHARS[(n >> 6) & 63] + B64_CHARS[n & 63]);
  }
  const rem = len - i;
  if (rem === 1) {
    const n = data[i] << 16;
    out.push(B64_CHARS[(n >> 18) & 63] + B64_CHARS[(n >> 12) & 63] + "==");
  } else if (rem === 2) {
    const n = (data[i] << 16) | (data[i + 1] << 8);
    out.push(B64_CHARS[(n >> 18) & 63] + B64_CHARS[(n >> 12) & 63] + B64_CHARS[(n >> 6) & 63] + "=");
  }
  return out.join("");
}

/** Decode base64 (the audio inside a timestamped speech response). Line
 * breaks, padding and anything else outside the alphabet are skipped; a
 * lone trailing character carries no whole byte and is dropped. */
export function b64Decode(data: string): Uint8Array {
  const s = String(data ?? "");
  const vals: number[] = [];
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    const v = c < 128 ? B64_VALUES[c] : -1;
    if (v >= 0) vals.push(v);
  }
  const len = vals.length;
  const out = new Uint8Array(Math.floor(len / 4) * 3 + (len % 4 === 3 ? 2 : len % 4 === 2 ? 1 : 0));
  let o = 0;
  let i = 0;
  for (; i + 3 < len; i += 4) {
    const n = (vals[i] << 18) | (vals[i + 1] << 12) | (vals[i + 2] << 6) | vals[i + 3];
    out[o++] = (n >> 16) & 255;
    out[o++] = (n >> 8) & 255;
    out[o++] = n & 255;
  }
  const rem = len - i;
  if (rem === 2) {
    out[o++] = (((vals[i] << 18) | (vals[i + 1] << 12)) >> 16) & 255;
  } else if (rem === 3) {
    const n = (vals[i] << 18) | (vals[i + 1] << 12) | (vals[i + 2] << 6);
    out[o++] = (n >> 16) & 255;
    out[o++] = (n >> 8) & 255;
  }
  return out;
}

/** A JS string as UTF-8 bytes. A lone surrogate becomes U+FFFD. */
export function utf8Encode(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let cp = s.charCodeAt(i);
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < s.length) {
      const lo = s.charCodeAt(i + 1);
      if (lo >= 0xdc00 && lo <= 0xdfff) {
        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
        i++;
      }
    }
    if (cp >= 0xd800 && cp <= 0xdfff) cp = 0xfffd;
    if (cp < 0x80) out.push(cp);
    else if (cp < 0x800) out.push(0xc0 | (cp >> 6), 0x80 | (cp & 63));
    else if (cp < 0x10000) out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
    else out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
  }
  return Uint8Array.from(out);
}

/** UTF-8 bytes as a JS string. Each byte of a malformed sequence becomes U+FFFD. */
export function utf8Decode(bytes: Uint8Array): string {
  const parts: string[] = [];
  let chunk: number[] = [];
  const flush = () => {
    parts.push(String.fromCharCode(...chunk));
    chunk = [];
  };
  const len = bytes.length;
  for (let i = 0; i < len; ) {
    const b = bytes[i];
    let cp = 0xfffd;
    let n = 1;
    if (b < 0x80) cp = b;
    else if (b >= 0xc2 && b < 0xe0) n = 2;
    else if (b >= 0xe0 && b < 0xf0) n = 3;
    else if (b >= 0xf0 && b < 0xf5) n = 4;
    if (n > 1) {
      let v = b & (n === 2 ? 0x1f : n === 3 ? 0x0f : 0x07);
      let ok = i + n <= len;
      for (let k = 1; ok && k < n; k++) {
        const c = bytes[i + k];
        if ((c & 0xc0) !== 0x80) ok = false;
        else v = (v << 6) | (c & 63);
      }
      const min = n === 2 ? 0x80 : n === 3 ? 0x800 : 0x10000;
      if (ok && v >= min && v <= 0x10ffff && !(v >= 0xd800 && v <= 0xdfff)) cp = v;
      else n = 1;
    }
    i += n;
    if (cp >= 0x10000) {
      cp -= 0x10000;
      chunk.push(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
    } else {
      chunk.push(cp);
    }
    if (chunk.length >= 8192) flush();
  }
  flush();
  return parts.join("");
}
