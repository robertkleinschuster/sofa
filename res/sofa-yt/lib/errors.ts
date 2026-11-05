// Caught values are `unknown`: everything this code (and its libraries) throws is an Error, but the
// type system cannot know that.

export function toError(e: unknown): Error {
  return e instanceof Error ? e : new Error(String(e));
}

export function errorMessage(e: unknown): string {
  return toError(e).message;
}
