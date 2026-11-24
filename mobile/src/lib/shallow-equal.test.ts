/// <reference types="bun" />
import { describe, expect, test } from 'bun:test';

import { shallowEqual, shouldLatch } from './shallow-equal';

describe('shallowEqual', () => {
  test('primitives compare by value, NaN equals NaN, 0 and -0 differ (Object.is)', () => {
    expect(shallowEqual(1, 1)).toBe(true);
    expect(shallowEqual('a', 'a')).toBe(true);
    expect(shallowEqual(true, true)).toBe(true);
    expect(shallowEqual(Number.NaN, Number.NaN)).toBe(true);
    expect(shallowEqual(1, 2)).toBe(false);
    expect(shallowEqual('1', 1)).toBe(false);
    expect(shallowEqual(0, -0)).toBe(false);
  });

  test('null and undefined only equal themselves', () => {
    expect(shallowEqual(null, null)).toBe(true);
    expect(shallowEqual(undefined, undefined)).toBe(true);
    expect(shallowEqual(null, undefined)).toBe(false);
    expect(shallowEqual(null, {})).toBe(false);
    expect(shallowEqual({}, undefined)).toBe(false);
  });

  test('the same reference is equal', () => {
    const o = { a: 1 };
    expect(shallowEqual(o, o)).toBe(true);
  });

  test('two fresh objects with the same keys and the same values are equal', () => {
    expect(shallowEqual({ a: 1, b: 'x' }, { a: 1, b: 'x' })).toBe(true);
    expect(shallowEqual({}, {})).toBe(true);
  });

  test('objects compare their values by reference, one level deep only', () => {
    const inner = { n: 1 };
    expect(shallowEqual({ inner }, { inner })).toBe(true);
    expect(shallowEqual({ inner: { n: 1 } }, { inner: { n: 1 } })).toBe(false);
  });

  test('a different value, a missing key or an extra key makes them differ', () => {
    expect(shallowEqual({ a: 1 }, { a: 2 })).toBe(false);
    expect(shallowEqual({ a: 1 }, { a: 1, b: 2 })).toBe(false);
    expect(shallowEqual({ a: 1, b: 2 }, { a: 1 })).toBe(false);
    expect(shallowEqual({ a: 1 }, { b: 1 })).toBe(false);
  });

  test('a key that is present as undefined is not the same as a missing key', () => {
    expect(shallowEqual({ a: undefined }, {})).toBe(false);
    expect(shallowEqual({}, { a: undefined })).toBe(false);
    expect(shallowEqual({ a: undefined }, { a: undefined })).toBe(true);
  });

  test('values are compared strictly, not loosely', () => {
    expect(shallowEqual({ a: 1 }, { a: '1' })).toBe(false);
    expect(shallowEqual({ a: 0 }, { a: false })).toBe(false);
    expect(shallowEqual({ a: null }, { a: undefined })).toBe(false);
    expect(shallowEqual({ a: '' }, { a: 0 })).toBe(false);
  });

  test('two objects with the same number of keys but different key names differ, even when the values are undefined', () => {
    expect(shallowEqual({ a: undefined }, { b: undefined })).toBe(false);
    expect(shallowEqual({ a: 1, b: undefined }, { a: 1, c: undefined })).toBe(false);
  });

  test('arrays compare element by element, by reference', () => {
    const x = { id: 1 };
    const y = { id: 2 };
    expect(shallowEqual([x, y], [x, y])).toBe(true);
    expect(shallowEqual([x, y], [y, x])).toBe(false);
    expect(shallowEqual([x], [x, y])).toBe(false);
    expect(shallowEqual([], [])).toBe(true);
    expect(shallowEqual([{ id: 1 }], [{ id: 1 }])).toBe(false);
  });

  test('an array is never equal to an object with the same entries', () => {
    expect(shallowEqual([1], { 0: 1 })).toBe(false);
    expect(shallowEqual({ 0: 1 }, [1])).toBe(false);
    expect(shallowEqual([], {})).toBe(false);
  });

  test('functions and class instances compare by reference only', () => {
    const f = () => 1;
    expect(shallowEqual(f, f)).toBe(true);
    expect(shallowEqual(() => 1, () => 1)).toBe(false);
    class P { x = 1 }
    expect(shallowEqual(new P(), new P())).toBe(false);
    const p = new P();
    expect(shallowEqual(p, p)).toBe(true);
  });

  test('a Date or a Map is not mistaken for a plain object', () => {
    expect(shallowEqual(new Date(0), new Date(0))).toBe(false);
    expect(shallowEqual(new Map(), new Map())).toBe(false);
  });
});

describe('shouldLatch (the decision behind useLatched)', () => {
  // THE regression: the Files screen builds `{ current, waiting }` inside its render. A fresh literal every time was "different" by reference,
  // so useLatched called setLast on every pass of the render-phase update and React gave up with "Too many re-renders".
  const entry = { id: 'a', status: 'active', done: 3 };

  test('a freshly built input equal to the latched one does NOT latch again (the bug)', () => {
    const last = { current: entry, waiting: 0 };
    const rebuilt = { current: entry, waiting: 0 };
    expect(rebuilt).not.toBe(last);
    expect(shouldLatch(rebuilt, last)).toBe(false);
  });

  test('the transfer entry changing latches (progress moved)', () => {
    expect(shouldLatch({ current: { ...entry, done: 4 }, waiting: 0 }, { current: entry, waiting: 0 })).toBe(true);
  });

  test('the waiting count changing latches', () => {
    expect(shouldLatch({ current: entry, waiting: 2 }, { current: entry, waiting: 1 })).toBe(true);
  });

  test('the first value latches (nothing latched yet)', () => {
    expect(shouldLatch({ current: entry, waiting: 0 }, undefined)).toBe(true);
  });

  test('null and undefined never latch: the old content stays while it animates out', () => {
    expect(shouldLatch(null, { current: entry, waiting: 0 })).toBe(false);
    expect(shouldLatch(undefined, { current: entry, waiting: 0 })).toBe(false);
    expect(shouldLatch(null, undefined)).toBe(false);
  });

  test('primitives: a new string latches, the same one does not (pair-screen error)', () => {
    expect(shouldLatch('boom', undefined)).toBe(true);
    expect(shouldLatch('boom', 'boom')).toBe(false);
    expect(shouldLatch('again', 'boom')).toBe(true);
  });

  test('an array rebuilt from the same entries does not latch (status-card stats)', () => {
    const a = { k: 1 };
    const b = { k: 2 };
    expect(shouldLatch([a, b], [a, b])).toBe(false);
    expect(shouldLatch([a], [a, b])).toBe(true);
  });

  test('falsy but non-null values still latch (0, empty string, false)', () => {
    expect(shouldLatch(0, undefined)).toBe(true);
    expect(shouldLatch('', undefined)).toBe(true);
    expect(shouldLatch(false, undefined)).toBe(true);
    expect(shouldLatch(0, 0)).toBe(false);
  });
});
