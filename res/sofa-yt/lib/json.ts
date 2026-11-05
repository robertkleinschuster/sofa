// Narrowing of untrusted JSON (YouTube responses, state files other processes write): parse into
// `unknown`, then check the shape before using it as a typed value.

export type JsonObject = Record<string, unknown>;

export function isRecord(x: unknown): x is JsonObject {
  return typeof x === 'object' && x !== null && !Array.isArray(x);
}

/** JSON.parse without the `any`: the caller narrows the result. */
export function parseJson(text: string): unknown {
  return JSON.parse(text) as unknown;
}

/** The value as an object (non-objects and arrays become `{}`). */
export function record(x: unknown): JsonObject {
  return isRecord(x) ? x : {};
}

/** The elements of an array that are objects; [] for anything else. */
export function records(x: unknown): JsonObject[] {
  return Array.isArray(x) ? x.filter(isRecord) : [];
}

export function optString(x: unknown): string | undefined {
  return typeof x === 'string' ? x : undefined;
}

export function optNumber(x: unknown): number | undefined {
  return typeof x === 'number' ? x : undefined;
}
