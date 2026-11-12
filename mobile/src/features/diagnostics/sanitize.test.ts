// TS 6 no longer auto-includes @types/*; scoping the Bun types to the test files keeps the app's
// own global types (RN, `__DEV__`) untouched.
/// <reference types="bun" />
import { describe, expect, test } from 'bun:test';

import {
  PLACEHOLDERS,
  knownValuesFrom,
  sanitizeLine,
  sanitizeLines,
  sanitizeText,
  type KnownValues,
} from './sanitize';

/** What this particular phone/Mac/relay would be called — values no pattern can know. */
const KNOWN: KnownValues = knownValuesFrom({
  pairing: { room: 'room-9f8e7d6c5b4a', key: 'a2V5LWJhc2U2NC1maXh0dXJlLTMyLWJ5dGVzIQ==', name: "Canary's MacBook" },
  server: { host: 'bifrost.example', token: 'tok-secret-123', lanHost: 'canary-mac.lan' },
  deviceName: 'Canary Pixel',
});

/** Real log lines (see docs/plans/2026-11-08-diagnostics-and-log-privacy.md §2) carrying canary data. */
const FIXTURES: string[] = [
  '12:03:11  clip [daemon]: CANARY-clip-7f3a is my password',
  '12:03:12  clip ⬆ "CANARY-clip-7f3a is my password…"',
  '12:03:13  share -> Mac file: canary-tax.pdf (1048576 B, 2 chunk(s), id=0a1b2c3d)',
  "12:03:14  share: couldn't read canary-tax.pdf: java.io.FileNotFoundException: /storage/emulated/0/Download/canary-tax.pdf: open failed",
  '12:03:15  share: no access to canary-tax.pdf: java.lang.SecurityException: content://com.canary.docs.provider/doc/canary-tax.pdf',
  '12:03:16  file saved to Downloads: canary-tax (1).pdf (2048 B)',
  "12:03:16  file: couldn't save canary-tax.pdf",
  '12:03:17  connection starting (relay=wss://bifrost.example/ws, lan=53124)',
  '12:03:18  relay fallback -> wss://bifrost.example:8443/ws?room=abc',
  '12:03:19  pairing 192.168.1.42:37123',
  '12:03:20  connecting 192.168.1.42:41233 (mDNS)',
  "12:03:21  mdns: found Mac at Canarys-MacBook.local:53124",
  '12:03:22  note dropped (service down): com.canary.app.notes',
  '12:03:23  image skipped: source com.canary.app lacks read access to com.android.providers.media.documents',
  '12:03:24  lan error Failed to connect to /192.168.1.42:53124',
  '12:03:25  relay error Unable to resolve host "bifrost.example": No address associated with hostname',
  "12:03:26  stat: name=Canary's MacBook battery=80",
  '12:03:27  openFile failed: Intent { act=android.intent.action.VIEW dat=content://media/external/downloads/42 flg=0x1 }',
  '12:03:28  pick: no persistable grant for content://com.android.externalstorage.documents/document/primary:Download/canary-tax.pdf: Permission Denial',
  '12:03:29  relay: error · wss://bifrost.example/ws closed (2001:db8::1)',
  '12:03:30  pair canary@example.com via +90 555 123 45 67',
  '12:03:31  ble: advertising 3f2a9c1b-7d4e-48f0-a1b2-c3d4e5f6a7b8',
  '12:03:32  daemon owner 02:00:5e:10:00:ff secret tok-secret-123',
  '12:03:33  phone Canary Pixel joined room room-9f8e7d6c5b4a',
];

/** None of these may survive sanitizing, in any fixture. */
const CANARIES = [
  'CANARY-clip-7f3a',
  'canary-tax',
  'bifrost.example',
  "Canary's MacBook",
  'Canarys-MacBook',
  'canary-mac.lan',
  'Canary Pixel',
  '192.168.1.42',
  '2001:db8',
  'com.canary',
  'canary@example.com',
  '555 123',
  'tok-secret-123',
  'room-9f8e7d6c5b4a',
  'content://',
  '/storage/emulated',
  '3f2a9c1b',
  '02:00:5e',
];

const run = (line: string) => sanitizeLine(line, KNOWN);

describe('rules', () => {
  test('clipboard text is replaced, the prefix and bare lengths stay', () => {
    expect(run(FIXTURES[0])).toBe('12:03:11  clip [daemon]: <clipboard text>');
    expect(run(FIXTURES[1])).toBe('12:03:12  clip ⬆ <clipboard text>');
    expect(run('12:03:11  clip [manual]: 42 chars')).toBe('12:03:11  clip [manual]: 42 chars');
    expect(run('12:03:12  clip ⬆ (42 chars)')).toBe('12:03:12  clip ⬆ (42 chars)');
    expect(run('12:03:13  clip -> clipboard via daemon')).toBe('12:03:13  clip -> clipboard via daemon');
  });

  test('file names are replaced, sizes and ids stay', () => {
    expect(run(FIXTURES[2])).toBe('12:03:13  share -> Mac file: <file> (1048576 B, 2 chunk(s), id=0a1b2c3d)');
    expect(run(FIXTURES[5])).toBe('12:03:16  file saved to Downloads: <file> (2048 B)');
    expect(run(FIXTURES[6])).toBe('12:03:16  file: couldn\'t save <file>');
  });

  test('a failed read keeps the exception class and loses name and path', () => {
    expect(run(FIXTURES[3])).toBe(
      "12:03:14  share: couldn't read <file>: java.io.FileNotFoundException: <path>: open failed",
    );
    expect(run(FIXTURES[4])).toBe('12:03:15  share: no access to <file>: java.lang.SecurityException: <path>');
  });

  test('relay and LAN addresses become <host>', () => {
    expect(run(FIXTURES[7])).toBe('12:03:17  connection starting (relay=<host>, lan=53124)');
    expect(run(FIXTURES[8])).toBe('12:03:18  relay fallback -> <host>');
    expect(run(FIXTURES[9])).toBe('12:03:19  pairing <host>');
    expect(run(FIXTURES[11])).toBe('12:03:21  mdns: found Mac at <host>');
    expect(run(FIXTURES[14])).toBe('12:03:24  lan error Failed to connect to /<host>');
    expect(run(FIXTURES[15])).toBe(
      '12:03:25  relay error Unable to resolve host "<host>": No address associated with hostname',
    );
  });

  test('IPv6 and hardware addresses are caught without eating clock times', () => {
    expect(sanitizeLine('12:03:29  peer fe80::1ff:fe23:4567:890a%wlan0 up')).toBe('12:03:29  peer <host> up');
    expect(sanitizeLine('x 2001:0db8:85a3:0000:0000:8a2e:0370:7334 y')).toBe('x <host> y');
    expect(sanitizeLine('12:34:56  relay: joined')).toBe('12:34:56  relay: joined');
    expect(sanitizeLine('addr 02:00:5e:10:00:ff')).toBe('addr <redacted>');
  });

  test('package names become <app>, our own and the platform classes stay', () => {
    expect(run(FIXTURES[12])).toBe('12:03:22  note dropped (service down): <app>');
    expect(run(FIXTURES[13])).toBe('12:03:23  image skipped: source <app> lacks read access to <app>');
    expect(sanitizeLine('crash in com.grkndev.linktomac.dev')).toBe('crash in com.grkndev.linktomac.dev');
    expect(sanitizeLine('expo.modules.selfadb.ClipBridge died')).toBe('expo.modules.selfadb.ClipBridge died');
    expect(sanitizeLine('java.lang.IllegalStateException: boom')).toBe('java.lang.IllegalStateException: boom');
    expect(sanitizeLine('android.os.DeadObjectException')).toBe('android.os.DeadObjectException');
  });

  test('content URIs and paths become <path>, including inside an Intent dump', () => {
    expect(run(FIXTURES[17])).toBe(
      '12:03:27  openFile failed: Intent { act=android.intent.action.VIEW dat=<path> flg=0x1 }',
    );
    expect(run(FIXTURES[18])).toBe('12:03:28  pick: no persistable grant for <path>: Permission Denial');
    expect(sanitizeLine('wrote /sdcard/Download/x.bin ok')).toBe('wrote <path> ok');
    expect(sanitizeLine('cat /data/data/com.x.y/files/k')).toBe('cat <path>');
  });

  test("the daemon's own log file location is not user data", () => {
    expect(sanitizeLine('tail -c 32768 /data/local/tmp/clip.log')).toBe('tail -c 32768 /data/local/tmp/clip.log');
  });

  test('e-mail, formatted phone numbers and opaque tokens', () => {
    expect(run(FIXTURES[20])).toBe('12:03:30  pair <redacted> via <redacted>');
    expect(sanitizeLine('call (555) 123-4567 now')).toBe('call <redacted> now');
    expect(run(FIXTURES[21])).toBe('12:03:31  ble: advertising <token>');
    expect(sanitizeLine('hash 3f2a9c1b7d4e8f0a1b2c3d4e5f6a7b8c9d0e1f2a')).toBe('hash <token>');
  });

  test('known values: Mac name, phone name, relay host and secrets', () => {
    expect(run(FIXTURES[16])).toBe('12:03:26  stat: name=<mac> battery=80');
    expect(run(FIXTURES[22])).toBe('12:03:32  daemon owner <redacted> secret <token>');
    expect(run(FIXTURES[23])).toBe('12:03:33  phone <phone> joined room <token>');
    expect(run('Canary\'s macbook, again')).toBe('<mac>, again');
  });

  test('numbers a bug report needs are left alone', () => {
    const keep = [
      '12:03:11  relay: joined · peer=online',
      '12:03:12  file: 12 chunks, 3 re-sent (id=0a1b2c3d)',
      '12:03:13  update: versionCode 260622001, v0.12.1, 1073741824 B',
      '12:03:14  server up. dex=20261112-1030 port=53123',
      '12:03:15  battery 80% (charging)',
      '12:03:16  status: adb=ok clip=live',
      'at ClipBus.kt:84',
      'ForegroundServiceStartNotAllowedException',
    ];
    for (const l of keep) expect(sanitizeLine(l)).toBe(l);
  });
});

describe('known values edge cases', () => {
  test('too-short and placeholder-like values are ignored instead of shredding text', () => {
    const k: KnownValues = { macNames: ['Mac', 'S9', ' '], hosts: ['host', null, undefined], phoneNames: [''] };
    const line = 'a Mac with S9 on the host: <mac> <host>';
    expect(sanitizeLine(line, k)).toBe(line);
  });

  test('longer values win over their prefixes', () => {
    const k: KnownValues = { phoneNames: ['Pixel 8', 'Pixel 8 Pro'] };
    expect(sanitizeLine('device Pixel 8 Pro online', k)).toBe('device <phone> online');
  });

  test('regex metacharacters in a value are matched literally', () => {
    const k: KnownValues = { macNames: ['Bob (work) [2].*'] };
    expect(sanitizeLine('paired with Bob (work) [2].* ok', k)).toBe('paired with <mac> ok');
  });
});

describe('invariants', () => {
  test('idempotent: sanitizing twice changes nothing', () => {
    for (const l of FIXTURES) {
      const once = run(l);
      expect(run(once)).toBe(once);
    }
  });

  test('idempotent even when a known value equals a placeholder word', () => {
    const k: KnownValues = { macNames: ['mac', 'Mac', 'file', 'text'], phoneNames: ['phone', 'path'] };
    for (const l of FIXTURES) {
      const once = sanitizeLine(l, k);
      expect(sanitizeLine(once, k)).toBe(once);
    }
  });

  test('canary: no sensitive string survives in any fixture', () => {
    const out = sanitizeLines(FIXTURES, KNOWN).join('\n');
    for (const c of CANARIES) expect(out.toLowerCase()).not.toContain(c.toLowerCase());
  });

  test('canary: nothing survives when the known values are NOT supplied either, except what only runtime knows', () => {
    // The patterns alone must already catch clipboard text, files, URLs, IPs, packages and paths.
    const out = sanitizeLines(FIXTURES).join('\n');
    for (const c of ['CANARY-clip-7f3a', 'canary-tax', 'bifrost.example', '192.168.1.42', 'com.canary', 'content://', '/storage/emulated']) {
      expect(out).not.toContain(c);
    }
  });

  test('only placeholders were introduced', () => {
    const allowed = new Set<string>(PLACEHOLDERS);
    const found = sanitizeLines(FIXTURES, KNOWN).join('\n').match(/<[a-z ]+>/g) ?? [];
    for (const f of found) expect(allowed.has(f)).toBe(true);
  });

  test('sanitizeText handles a multi-line daemon log blob and keeps line structure', () => {
    const blob = ['11:00:00  server up. dex=20261112-1030', FIXTURES[0], FIXTURES[9], ''].join('\n');
    const out = sanitizeText(blob, KNOWN);
    expect(out.split('\n')).toHaveLength(4);
    expect(out).toContain('server up. dex=20261112-1030');
    expect(out).not.toContain('CANARY');
    expect(out).not.toContain('192.168');
  });

  test('no known values at all is fine', () => {
    expect(sanitizeLine('plain line')).toBe('plain line');
    expect(sanitizeLines([])).toEqual([]);
    expect(sanitizeLine('x', knownValuesFrom({}))).toBe('x');
  });
});
