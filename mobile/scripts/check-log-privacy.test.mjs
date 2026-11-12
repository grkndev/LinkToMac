import { describe, expect, test } from 'bun:test';

import { findViolations } from './check-log-privacy.mjs';

const kt = (code) => findViolations(code, 'kt');
const java = (code) => findViolations(code, 'java');
const ts = (code) => findViolations(code, 'ts');
const names = (violations) => violations.flatMap((v) => v.names);

describe('catches the real leaks this guard exists for (the lines as they were before the fix)', () => {
  test.each([
    ['clipboard text', 'ClipBus.log("clip [${source.label}]: ${text.take(60)}")', 'text'],
    ['relay url', 'ClipBus.log("connection starting (relay=${if (url.isEmpty()) "none" else url}, lan=off)")', 'url'],
    ['file name', 'ClipBus.log("share -> Mac file: $name ($total B, $count chunk(s), id=$id)")', 'name'],
    ['file name + message', 'ClipBus.log("share: couldn\'t read $name: ${e.message}")', 'name'],
    ['relay fallback', 'log("relay fallback -> $relayUrl")', 'relayUrl'],
    ['LAN address', 'log("pairing $host:$port")', 'host'],
    ['mDNS address', 'log("mdns: found Mac at $host:${serviceInfo.port}")', 'host'],
    ['package name', 'ClipBus.log("note dropped (service down): $pkg")', 'pkg'],
    ['content uri', 'ClipBus.log("pick: no persistable grant for $uri: ${e.message}")', 'uri'],
  ])('kotlin: %s', (_label, code, name) => {
    expect(names(kt(code))).toContain(name);
  });

  test('java: concatenation in the daemon', () => {
    expect(names(java('log("image skipped: source " + srcPkg + " lacks read access to " + uri.getAuthority());'))).toEqual(
      expect.arrayContaining(['srcPkg', 'uri', 'getAuthority']),
    );
  });

  test('typescript: the Logs screen line and console calls', () => {
    expect(names(ts('append(`${clock()}  clip ⬆ "${preview(e.text, 50)}"`)'))).toContain('text');
    expect(names(ts('console.log(`paired with ${pairing.name}`)'))).toContain('name');
  });
});

describe('does not cry wolf', () => {
  test.each([
    ['the fixed clip line', 'ClipBus.log("clip [${source.label}]: ${text.length} chars")'],
    ['literal text that merely contains a forbidden word', 'ClipBus.log("no text on the clipboard, skipping")'],
    ['a nested string inside an interpolation', 'ClipBus.log("(relay=${if (url.isEmpty()) "none" else "on"}, lan=off)")'],
    ['an exception class name', 'ClipBus.log("share: read failed (${e.javaClass.simpleName})")'],
    ['a null check', 'log("listening " + port + (secret != null ? " (auth required)" : ""))'],
    ['a function that only looks like log', 'logRetry("x $text")'],
    ['a comment', '// log("leaks $text")'],
    ['a doc comment', ' * ClipBus.log("leaks $text") is what NOT to do'],
  ])('%s', (_label, code) => {
    expect(kt(code)).toEqual([]);
  });

  test('typescript: lengths and unrelated calls', () => {
    expect(ts('append(`${clock()}  clip ⬆ (${e.text.length} chars)`)')).toEqual([]);
    expect(ts('const x = items.append(name)')).toEqual([]);
  });
});

describe('mechanics', () => {
  test('multi-line calls are read to the closing paren', () => {
    const src = 'ClipBus.log(\n  "clip: " +\n    text\n)\n';
    expect(names(kt(src))).toEqual(['text']);
    expect(kt(src)[0].line).toBe(1);
  });

  test('"log-privacy: ok" on the call line silences it (and only that call)', () => {
    const src = [
      'ClipBus.log("a $name") // log-privacy: ok — our own file',
      'ClipBus.log("b $name")',
    ].join('\n');
    const v = kt(src);
    expect(v).toHaveLength(1);
    expect(v[0].line).toBe(2);
  });

  test('reports each leaking call with its line', () => {
    const src = 'fun a() {}\nlog("x $host")\nlog("y $addr")\n';
    expect(kt(src).map((v) => v.line)).toEqual([2, 3]);
  });

  test('kotlin: `$name.length` interpolates name itself, so it is flagged', () => {
    expect(names(kt('log("len $text.length")'))).toContain('text');
  });
});
