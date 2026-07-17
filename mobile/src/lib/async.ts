/** Distinguishes "call stalled past its deadline" from a real error in a catch. */
export class TimeoutError extends Error {}

/** Race `promise` against a `ms` deadline; rejects with {@link TimeoutError} on timeout. */
export function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new TimeoutError(`${label} did not respond within ${ms} ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}
