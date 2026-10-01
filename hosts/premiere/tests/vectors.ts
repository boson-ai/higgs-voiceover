// Shared test vectors (../../shared/vectors), written by the Resolve build's
// tests/vectors.lua. Each case is a call into that build and what it returned;
// the TypeScript port must return the same.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { strict as assert } from "node:assert";

export interface VectorCase {
  name: string;
  fn: string;
  input: any;
  expect: any;
}

export function loadVectors(topic: string): VectorCase[] {
  const url = new URL(`../../../shared/vectors/${topic}.json`, import.meta.url);
  const data = JSON.parse(readFileSync(fileURLToPath(url), "utf8"));
  return data.cases as VectorCase[];
}

/** Deep equality where numbers may differ by float noise (the vectors keep 12 digits). */
export function assertClose(actual: unknown, expected: unknown, path = "$"): void {
  if (typeof expected === "number" && typeof actual === "number") {
    const tol = 1e-9 * Math.max(1, Math.abs(expected));
    assert.ok(Math.abs(actual - expected) <= tol, `${path}: got ${actual}, want ${expected}`);
    return;
  }
  if (Array.isArray(expected)) {
    assert.ok(Array.isArray(actual), `${path}: want a list, got ${JSON.stringify(actual)}`);
    assert.equal((actual as unknown[]).length, expected.length, `${path}: length`);
    expected.forEach((e, i) => assertClose((actual as unknown[])[i], e, `${path}[${i}]`));
    return;
  }
  if (expected && typeof expected === "object") {
    assert.ok(actual && typeof actual === "object" && !Array.isArray(actual), `${path}: want a record, got ${JSON.stringify(actual)}`);
    const a = actual as Record<string, unknown>;
    for (const k of Object.keys(expected)) assertClose(a[k], (expected as Record<string, unknown>)[k], `${path}.${k}`);
    for (const k of Object.keys(a)) {
      if (a[k] !== undefined && !(k in (expected as object))) assert.fail(`${path}.${k}: unexpected field`);
    }
    return;
  }
  assert.deepEqual(actual, expected, path);
}
