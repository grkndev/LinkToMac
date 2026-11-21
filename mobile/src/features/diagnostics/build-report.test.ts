// TS 6 no longer auto-includes @types/*; scoping the Bun types to the test files keeps the app's
// own global types (RN, `__DEV__`) untouched.
/// <reference types="bun" />
import { describe, expect, test } from 'bun:test';

import {
  MAX_APP_LOG_LINES,
  MAX_ISSUE_URL,
  MAX_SUMMARY,
  buildIssueSummary,
  buildReport,
  issueUrl,
  type ReportData,
} from './build-report';
import { knownValuesFrom } from './sanitize';

const KNOWN = knownValuesFrom({
  pairing: { room: 'room-9f8e7d6c5b4a', key: 'a2V5LWJhc2U2NC1maXh0dXJlLTMyLWJ5dGVzIQ==', name: "Canary's MacBook" },
  server: { host: 'bifrost.example', token: 'tok-secret-123' },
  deviceName: 'Canary Pixel',
});

/** Canary data planted in EVERY free-text field the report accepts. */
const CANARIES = [
  'CANARY-clip-7f3a',
  'canary-tax.pdf',
  'bifrost.example',
  "Canary's MacBook",
  'Canary Pixel',
  '192.168.1.42',
  'tok-secret-123',
  'room-9f8e7d6c5b4a',
  // The QUIC data plane's values (stage 1.9): none may survive in the report or the summary.
  '192.168.1.10',
  '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd',
  '123e4567-e89b-12d3-a456-426614174000',
  'abcdefab-cdef-abcd-efab-cdefabcdefab',
  'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
];

function data(overrides: Partial<ReportData> = {}): ReportData {
  return {
    generatedAt: new Date('2026-11-12T10:00:00Z'),
    app: {
      version: '0.13.0',
      versionCode: 261112001,
      packageName: 'com.grkndev.linktomac',
      channel: 'preview',
      runtimeVersion: '0.13.0',
      updateId: '5b7d3c1e-0000-4000-8000-000000000001',
      embedded: false,
      updatesEnabled: true,
    },
    device: { manufacturer: 'Google', model: 'Pixel 8', osVersion: '15', apiLevel: 35 },
    status: {
      paired: true,
      relayConfigured: true,
      lanEnabled: true,
      relay: {
        status: 'joined',
        transport: 'lan',
        peerOnline: true,
        attempt: 0,
        lastError: 'Failed to connect to /192.168.1.42:53124 (bifrost.example)',
      },
      capture: { state: 'needs-setup', reason: 'debugging-unreachable', error: 'adb 192.168.1.42:41233 timed out' },
      daemonAlive: false,
    },
    permissions: [
      { name: 'Notifications', granted: true },
      { name: 'SMS read', granted: false },
      { name: 'Battery optimization ignored', granted: null },
    ],
    // Free-text fields carry what the real code/OS can put there: URLs, paths, packages, addresses.
    // (A bare word like a file name can't be recognised — that is what source-side logging is for.)
    update: { state: 'failed', version: '0.13.1', error: 'download from https://bifrost.example/canary-tax.pdf failed' },
    exits: [
      {
        timestamp: Date.UTC(2026, 10, 11, 8, 30, 0),
        reason: 'LOW_MEMORY',
        importance: 'CACHED',
        status: 0,
        description: 'kill com.canary.app reading /storage/emulated/0/canary-tax.pdf from 192.168.1.42',
      },
      { timestamp: Date.UTC(2026, 10, 10, 7, 0, 0), reason: 'USER_REQUESTED' },
    ],
    // Fixed sentences in real life; here they are hostile on purpose (the sanitizer is the second defence).
    quic: {
      available: true,
      state: 'Connected',
      last: 'failed to reach 192.168.1.10:53125, pinned 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef, session 123e4567-e89b-12d3-a456-426614174000',
      reason: 'token AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8 and abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd, id abcdefab-cdef-abcd-efab-cdefabcdefab',
      rttMs: 4,
      lostPackets: 2,
      congestionEvents: 1,
    },
    daemonLog: ['10:00:00  clip [daemon]: CANARY-clip-7f3a', '10:00:01  image skipped: source com.canary.app lacks access'],
    appLog: ["10:00:02  stat: name=Canary's MacBook", '10:00:03  connecting 192.168.1.42:41233 (mDNS)', '10:00:04  phone Canary Pixel'],
    ...overrides,
  };
}

describe('buildReport', () => {
  test('contains the expected sections and facts', () => {
    const r = buildReport(data(), KNOWN);
    for (const s of ['App', 'Device', 'State', 'QUIC data plane', 'Permissions', 'Updates', 'Recent exits', 'Daemon log', 'App log']) {
      expect(r.text).toContain(`── ${s}`);
    }
    expect(r.text).toContain('Version: 0.13.0 (build 261112001)');
    expect(r.text).toContain('Device: Google Pixel 8');
    expect(r.text).toContain('Link: joined via lan, Mac online');
    expect(r.text).toContain('SMS read: no');
    expect(r.text).toContain('Battery optimization ignored: unknown');
    expect(r.text).toContain('2026-11-11 08:30:00 UTC  LOW_MEMORY · CACHED · status 0');
    expect(r.text).toContain('USER_REQUESTED');
    expect(r.text).toContain('Relay configured: yes');
  });

  test('canary: no sensitive string survives in the text or the summary', () => {
    const r = buildReport(data(), KNOWN);
    for (const c of CANARIES) {
      expect(r.text.toLowerCase()).not.toContain(c.toLowerCase());
      expect(r.summary.toLowerCase()).not.toContain(c.toLowerCase());
    }
  });

  test('lines and text are the same thing, so the preview is what gets shared', () => {
    const r = buildReport(data(), KNOWN);
    expect(r.lines.join('\n')).toBe(r.text);
  });

  test('exit reasons: unsupported APK, failed call, and none recorded each say so', () => {
    expect(buildReport(data({ exits: 'unsupported' }), KNOWN).text).toContain('Not available in this build');
    expect(buildReport(data({ exits: null }), KNOWN).text).toContain('Could not be read.');
    expect(buildReport(data({ exits: [] }), KNOWN).text).toContain('None recorded.');
  });

  test('logs: keeps only the tail, and says so when unreadable', () => {
    const many = Array.from({ length: MAX_APP_LOG_LINES + 50 }, (_, i) => `10:00:00  line ${i}`);
    const r = buildReport(data({ appLog: many, daemonLog: null }), KNOWN);
    expect(r.text).toContain(`line ${MAX_APP_LOG_LINES + 49}`);
    expect(r.text).not.toContain('line 49\n');
    expect(r.text).toContain('Could not be read.');
  });

  test('the report is idempotent under the sanitizer: nothing left to remove', () => {
    const r = buildReport(data(), KNOWN);
    // re-running the same inputs gives the same text (no state, no clock besides generatedAt)
    expect(buildReport(data(), KNOWN).text).toBe(r.text);
  });
});

describe('QUIC data plane section (stage 1.9)', () => {
  const quicText = (overrides: Partial<NonNullable<Extract<ReportData['quic'], object>>> = {}) =>
    buildReport(
      data({ quic: { available: true, state: 'Connected', last: 'connected', reason: null, rttMs: 4, lostPackets: 2, congestionEvents: 1, ...overrides } }),
      KNOWN,
    ).text;

  test('says whether QUIC is usable, the session, the last outcome and the link numbers', () => {
    const t = quicText();
    expect(t).toContain('Available: yes');
    expect(t).toContain('Session: Connected');
    expect(t).toContain('Last: connected');
    expect(t).toContain('Round trip: 4 ms · packets lost: 2 · congestion events: 1');
  });

  test('a session that is not open has no link numbers', () => {
    const t = quicText({ available: false, state: 'Idle', reason: 'needs the same Wi-Fi (the LAN-direct link)', last: null, rttMs: null, lostPackets: null, congestionEvents: null });
    expect(t).toContain('Available: no (needs the same Wi-Fi (the LAN-direct link))');
    expect(t).toContain('Session: Idle');
    expect(t).not.toContain('Round trip');
    expect(t).not.toContain('Last:');
  });

  test('a number that is not a number shows as a dash, never as text', () => {
    const t = quicText({ rttMs: 4, lostPackets: Number.NaN, congestionEvents: undefined as unknown as number });
    expect(t).toContain('packets lost: — · congestion events: —');
  });

  test('an APK that predates the QUIC work and a failed read each say so', () => {
    const before = buildReport(data({ quic: 'unsupported' }), KNOWN).lines;
    const at = before.indexOf('── QUIC data plane ──');
    expect(before[at + 1]).toBe('Not available in this build (needs a newer APK).');
    const failed = buildReport(data({ quic: null }), KNOWN).lines;
    expect(failed[failed.indexOf('── QUIC data plane ──') + 1]).toBe('Could not be read.');
  });

  test('every free-text field is sanitized: the hostile strings leave nothing behind', () => {
    const t = quicText({
      last: 'to 192.168.1.10:53125 fp abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd sid abcdefab-cdef-abcd-efab-cdefabcdefab',
      reason: 'tok AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
      state: 'Ended(192.168.1.10:53125)',
    });
    for (const c of ['192.168.1.10', 'abcdefabcdefabcdef', 'abcdefab-cdef', 'AAECAwQFBgcICQoL']) expect(t).not.toContain(c);
    expect(t).toContain('<host>');
    expect(t).toContain('<token>');
  });

  test('the reason QUIC is unavailable is sanitized too (it shows only when QUIC is not available)', () => {
    const t = quicText({ available: false, state: 'Idle', reason: 'no route to 192.168.1.10:53125, tok AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8', rttMs: null, lostPackets: null, congestionEvents: null });
    expect(t).toContain('Available: no (no route to <host>, tok <token>)');
    expect(t).not.toContain('192.168.1.10');
  });

  test('the section sits between State and Permissions', () => {
    const lines = buildReport(data(), KNOWN).lines;
    const at = (title: string) => lines.indexOf(`── ${title} ──`);
    expect(at('State')).toBeLessThan(at('QUIC data plane'));
    expect(at('QUIC data plane')).toBeLessThan(at('Permissions'));
  });
});

describe('issue summary and URL', () => {
  test('summary carries one QUIC line made of enum words only', () => {
    expect(buildIssueSummary(data())).toContain('QUIC: yes, session Connected');
    expect(buildIssueSummary(data({ quic: { available: false, state: 'Ended(end=PeerRejected(reason=RELAY))', rttMs: null } }))).toContain('QUIC: no, session Ended');
    expect(buildIssueSummary(data({ quic: 'unsupported' }))).toContain('QUIC: not in this build');
    expect(buildIssueSummary(data({ quic: null }))).toContain('QUIC: unknown');
  });

  test('a hostile session state cannot put anything but a word into the summary', () => {
    const summary = buildIssueSummary(data({ quic: { available: true, state: 'Connected 192.168.1.10:53125 123e4567-e89b-12d3-a456-426614174000' } }));
    expect(summary).toContain('QUIC: yes, session Connected');
    expect(summary).not.toContain('192.168.1.10');
    expect(summary).not.toContain('123e4567');
  });

  test('summary is short and free of log lines', () => {
    const s = buildIssueSummary(data());
    expect(s.length).toBeLessThanOrEqual(MAX_SUMMARY);
    expect(s).toContain('App: 0.13.0');
    expect(s).toContain('Recent exits: LOW_MEMORY, USER_REQUESTED');
    expect(s).not.toContain('Failed to connect');
  });

  test('a debug build says its JS comes from the dev server, not "OTA update"', () => {
    const dev = data({ app: { ...data().app, devBundle: true, embedded: false, updateId: null } });
    expect(buildReport(dev, KNOWN).text).toContain('JS bundle: dev server (debug build)');
    expect(buildReport(dev, KNOWN).text).not.toContain('JS bundle: OTA update');
    expect(buildIssueSummary(dev)).toContain('dev-server bundle');
    // a real OTA build is unchanged
    expect(buildReport(data(), KNOWN).text).toContain('JS bundle: OTA update 5b7d3c1e');
  });

  test('summary is hard-capped', () => {
    const long = data({ app: { ...data().app, channel: 'x'.repeat(5000) } });
    expect(buildIssueSummary(long).length).toBeLessThanOrEqual(MAX_SUMMARY);
  });

  test('issue URL prefills the form field by id and stays under the limit', () => {
    const url = issueUrl(buildIssueSummary(data()));
    expect(url.startsWith('https://github.com/grkndev/LinkToMac/issues/new?template=bug_report.yml')).toBe(true);
    expect(url).toContain('&summary=');
    expect(url.length).toBeLessThanOrEqual(MAX_ISSUE_URL);
    expect(decodeURIComponent(url.split('&summary=')[1].split('&')[0])).toContain('App: 0.13.0');
  });

  test('the summary is also sent as body=, because the GitHub Android app ignores form fields', () => {
    const summary = buildIssueSummary(data());
    const q = new URL(issueUrl(summary)).searchParams;
    expect(q.get('summary')).toBe(summary);
    expect(q.get('body')).toBe(summary);
    expect(q.get('template')).toBe('bug_report.yml');
  });

  test('an over-long summary is shrunk until the URL fits', () => {
    const url = issueUrl('é'.repeat(5000));
    expect(url.length).toBeLessThanOrEqual(MAX_ISSUE_URL);
  });
});
