/**
 * Shallow equality, the one comparison `useLatched` needs.
 *
 * Why it exists: `useLatched` used to compare its input with `!==`. A screen that builds the input inside its own render (the Files screen's
 * `{ current, waiting }`) hands it a NEW object every pass, so it always looked "changed", and calling `setLast` during render on every pass
 * never converges: React stops with "Too many re-renders". Comparing one level deep makes an equal rebuild a no-op.
 *
 * Rules: primitives by `Object.is` (so NaN equals NaN and 0 differs from -0); plain objects and arrays key by key / element by element with
 * `Object.is` (one level only: nested objects compare by reference); an array never equals an object; anything else (functions, Date, Map,
 * class instances, React elements) is equal only to itself, so a changing element still latches like before.
 */
export function shallowEqual(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null) return false;
  const aIsArray = Array.isArray(a);
  if (aIsArray !== Array.isArray(b)) return false;
  if (aIsArray) {
    const x = a as unknown[];
    const y = b as unknown[];
    return x.length === y.length && x.every((v, i) => Object.is(v, y[i]));
  }
  if (!isPlainObject(a) || !isPlainObject(b)) return false;
  const ka = Object.keys(a);
  const kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  return ka.every((k) => Object.prototype.hasOwnProperty.call(b, k) && Object.is(a[k], b[k]));
}

function isPlainObject(v: object): v is Record<string, unknown> {
  const proto = Object.getPrototypeOf(v);
  return proto === Object.prototype || proto === null;
}

/**
 * Whether `useLatched` should store `value` as the new latched content: only a real value (never null/undefined: the old content has to stay
 * on screen while it animates out) that is not shallow-equal to what is already latched.
 */
export function shouldLatch(value: unknown, last: unknown): boolean {
  return value != null && !shallowEqual(value, last);
}
