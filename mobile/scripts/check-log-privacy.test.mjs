import { describe, expect, test } from 'bun:test';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

import { QUIC_FORBIDDEN, findViolations } from './check-log-privacy.mjs';

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
    ['a null check', 'log("listening on loopback" + (secret != null ? " (auth required)" : ""))'],
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

// ── stage 1.9: the QUIC data plane's secrets ────────────────────────────────────────────────
// An address, a port, a certificate fingerprint, a session token and a session id travel through the QUIC code. None of them may reach a
// log line, and no log line may interpolate the object that holds them all (the offer's toString() writes every one).

describe('QUIC secrets (stage 1.9): catches the lines that would leak them', () => {
  test.each([
    ['the whole offer (its toString holds sid, port, fp and tok)', 'ClipBus.log("quic offer $offer")', 'offer'],
    ['the fingerprint as a property', 'log("pinned ${c.fp}")', 'fp'],
    ['the token, concatenated', 'log("token: " + tok)', 'tok'],
    ['the session id', 'ClipBus.log("session $sid started")', 'sid'],
    ['the port', 'log("connecting, port $port")', 'port'],
    ['the hex fingerprint as the client receives it', 'log("fp $fpHex")', 'fpHex'],
    ['the base64 token as the client receives it', 'log("tok $tokB64")', 'tokB64'],
    ['the Mac\'s LAN address', 'log("to $hostAddress")', 'hostAddress'],
    ['the LAN host', 'ClipBus.log("lan host ${lanHost}")', 'lanHost'],
    ['a session id spelled out', 'log("id $sessionId")', 'sessionId'],
    ['a certificate fingerprint spelled out', 'log("cert ${certFingerprint}")', 'certFingerprint'],
  ])('kotlin: %s', (_label, code, name) => {
    expect(names(kt(code))).toContain(name);
  });

  test('typescript: a template that interpolates the token or the fingerprint', () => {
    expect(names(ts('console.log(`pinned ${fp}`)'))).toContain('fp');
    expect(names(ts('append(`${clock()}  token ${tok}`)'))).toContain('tok');
  });

  test('every QUIC name is in the list and the list has no duplicates', () => {
    for (const n of ['tok', 'fp', 'port', 'sid', 'offer', 'fpHex', 'tokB64', 'hostAddress']) expect(QUIC_FORBIDDEN).toContain(n);
    expect(new Set(QUIC_FORBIDDEN).size).toBe(QUIC_FORBIDDEN.length);
  });
});

describe('QUIC secrets (stage 1.9): does not cry wolf', () => {
  test.each([
    ['a fixed sentence', 'ClipBus.log("quic: connecting")'],
    ['an enum of what went wrong', 'log("quic: connect refused (${result.reason})")'],
    ['a length', 'log("tok ${tok.length} bytes")'],
    ['asking whether it is there', 'log("sid known: ${sid != null}")'],
    ['an offer null check', 'log("offer " + (offer != null))'],
    ['literal text that merely contains the words', 'log("the port, the fp and the tok stay out of the log")'],
  ])('kotlin: %s', (_label, code) => {
    expect(kt(code)).toEqual([]);
  });

  test('the escape comment silences one call and only that call', () => {
    const src = [
      'ClipBus.log("bridge on :$port") // log-privacy: ok — the daemon bridge\'s own loopback port',
      'ClipBus.log("again $port")',
    ].join('\n');
    expect(kt(src).map((v) => v.line)).toEqual([2]);
  });

  test('java is not held to the QUIC names (the daemon has no QUIC and its dex asset must not go stale)', () => {
    expect(java('log("listening 127.0.0.1:" + port);')).toEqual([]);
    expect(names(java('log("x " + uri);'))).toEqual(['uri']);   // the older rule still applies there
  });
});

describe('the repository itself', () => {
  const quicDir = join(import.meta.dir, '../modules/selfadb/android/src/main/java/expo/modules/selfadb');
  const files = [
    ...readdirSync(join(quicDir, 'quic')).filter((f) => f.endsWith('.kt')).map((f) => join(quicDir, 'quic', f)),
    join(quicDir, 'ClipForegroundService.kt'),
    join(quicDir, 'ConnectionManager.kt'),
    join(quicDir, 'LanDiscovery.kt'),
  ];

  test.each(files.map((f) => [f.slice(quicDir.length + 1), f]))('%s logs none of the QUIC secrets', (_name, file) => {
    expect(kt(readFileSync(file, 'utf8'))).toEqual([]);
  });

  test('only the two reasoned `port` lines carry the escape comment', () => {
    const escaped = files.flatMap((f) => readFileSync(f, 'utf8').split('\n').filter((l) => l.includes('log-privacy: ok') && /port/i.test(l)));
    expect(escaped).toHaveLength(2);
  });
});
