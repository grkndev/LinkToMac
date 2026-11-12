import { NEW_ISSUE_URL } from '@/constants/links';

import { sanitizeLine, sanitizeLines, type KnownValues } from './sanitize';

/**
 * The diagnostics report: what "Send diagnostics" previews, shares and summarises into a GitHub
 * issue. Pure — it takes plain data (collected by `use-diagnostics.ts`) and returns text, so the
 * privacy properties are testable without a phone.
 *
 * What is NEVER in here, by construction: clipboard text, file names, addresses/IPs, the Mac's or
 * the phone's name, the pairing room/key, SMS/notification content, the installed-app list. The
 * fields below simply don't exist for those; every free-text field (log lines, error messages,
 * exit descriptions) goes through the sanitizer; and the relay is reported as configured yes/no.
 */

/** `null` = the check itself failed or timed out ("unknown" — not "no"). */
export type Granted = boolean | null;

/** One row of `ActivityManager.getHistoricalProcessExitReasons`. Structural twin of the module's type. */
export type ExitRecord = {
  timestamp: number;
  reason: string;
  importance?: string;
  status?: number;
  description?: string;
};

export interface ReportData {
  generatedAt: Date;
  app: {
    version: string;
    versionCode?: string | number | null;
    packageName?: string | null;
    channel?: string | null;
    runtimeVersion?: string | null;
    updateId?: string | null;
    /** true = running the JS that shipped in the APK, false = an OTA update, null = unknown. */
    embedded?: boolean | null;
    /** A debug build loading its JS from Metro: neither "embedded" nor an OTA update. */
    devBundle?: boolean;
    updatesEnabled?: boolean | null;
  };
  device: {
    manufacturer?: string | null;
    model?: string | null;
    osVersion?: string | null;
    apiLevel?: number | null;
  };
  status: {
    paired: boolean;
    /** Whether a relay endpoint is saved — never its address. */
    relayConfigured: boolean;
    lanEnabled?: boolean | null;
    relay?: {
      status: string;
      transport?: string | null;
      peerOnline: boolean;
      attempt?: number | null;
      lastError?: string | null;
    } | null;
    capture?: { state: string; reason?: string | null; error?: string | null } | null;
    daemonAlive?: boolean | null;
  };
  permissions: { name: string; granted: Granted }[];
  update?: { state: string; version?: string | null; error?: string | null } | null;
  /** `'unsupported'` = the installed APK predates `getExitReasons`; `null` = the call failed. */
  exits: ExitRecord[] | 'unsupported' | null;
  daemonLog: string[] | null;
  appLog: string[] | null;
}

export interface Report {
  /** Exactly what Share sends and what the preview shows. */
  text: string;
  lines: string[];
  /** ≤ MAX_SUMMARY chars: what the GitHub issue form is pre-filled with. */
  summary: string;
}

export const MAX_SUMMARY = 1200;
/** GitHub rejects very long query strings; stay well under its ~8 KB. */
export const MAX_ISSUE_URL = 7500;
export const MAX_APP_LOG_LINES = 200;
export const MAX_DAEMON_LOG_LINES = 100;

const yesNo = (v: boolean | null | undefined): string => (v == null ? 'unknown' : v ? 'yes' : 'no');
const orDash = (v: string | number | null | undefined): string => (v == null || v === '' ? '—' : String(v));

function utc(ms: number): string {
  return new Date(ms).toISOString().replace('T', ' ').slice(0, 19) + ' UTC';
}

function section(title: string, rows: string[]): string[] {
  return ['', `── ${title} ──`, ...rows];
}

export function buildReport(data: ReportData, known?: KnownValues): Report {
  const clean = (t: string | null | undefined): string => (t ? sanitizeLine(t, known) : '');
  const { app, device, status } = data;

  const appRows = [
    `Version: ${app.version} (build ${orDash(app.versionCode)})`,
    `Package: ${orDash(app.packageName)}`,
    `Channel: ${orDash(app.channel)}`,
    `Runtime: ${orDash(app.runtimeVersion)}`,
    `JS bundle: ${
      app.devBundle
        ? 'dev server (debug build)'
        : app.embedded == null
          ? 'unknown'
          : app.embedded
            ? 'embedded in the APK'
            : `OTA update ${orDash(app.updateId)}`
    }`,
    `OTA updates: ${app.updatesEnabled == null ? 'unknown' : app.updatesEnabled ? 'enabled' : 'disabled'}`,
  ];

  const deviceRows = [
    `Device: ${[device.manufacturer, device.model].filter(Boolean).join(' ') || '—'}`,
    `Android: ${orDash(device.osVersion)} (API ${orDash(device.apiLevel)})`,
  ];

  const relay = status.relay;
  const link = relay
    ? `${relay.status}${relay.transport ? ` via ${relay.transport}` : ''}, Mac ${relay.peerOnline ? 'online' : 'offline'}` +
      (relay.attempt ? `, reconnect attempt ${relay.attempt}` : '')
    : 'unknown';
  const statusRows = [
    `Paired with a Mac: ${yesNo(status.paired)}`,
    `Relay configured: ${yesNo(status.relayConfigured)}`,
    `LAN-direct: ${status.lanEnabled == null ? 'unknown' : status.lanEnabled ? 'on' : 'off'}`,
    `Link: ${link}`,
    ...(relay?.lastError ? [`Last link error: ${clean(relay.lastError)}`] : []),
    `Automatic capture: ${
      status.capture
        ? `${status.capture.state}${status.capture.reason ? ` (${status.capture.reason})` : ''}`
        : 'unknown'
    }`,
    ...(status.capture?.error ? [`Capture error: ${clean(status.capture.error)}`] : []),
    `Daemon alive: ${yesNo(status.daemonAlive)}`,
  ];

  const permissionRows = data.permissions.map((p) => `${p.name}: ${yesNo(p.granted)}`);

  const updateRows = data.update
    ? [
        `App update: ${data.update.state}${data.update.version ? ` (${data.update.version})` : ''}`,
        ...(data.update.error ? [`Update error: ${clean(data.update.error)}`] : []),
      ]
    : ['App update: unknown'];

  const exitRows =
    data.exits === 'unsupported'
      ? ['Not available in this build (needs a newer APK).']
      : data.exits === null
        ? ['Could not be read.']
        : data.exits.length === 0
          ? ['None recorded.']
          : data.exits.map(
              (e) =>
                `${utc(e.timestamp)}  ${e.reason}` +
                (e.importance ? ` · ${e.importance}` : '') +
                (e.status != null ? ` · status ${e.status}` : '') +
                (e.description ? ` — ${clean(e.description)}` : ''),
            );

  const tail = (lines: string[] | null, max: number, empty: string): string[] =>
    lines === null ? ['Could not be read.'] : lines.length === 0 ? [empty] : sanitizeLines(lines.slice(-max), known);

  const lines = [
    'Link to Mac — diagnostics report',
    `Generated ${utc(data.generatedAt.getTime())}`,
    'Built on this device. Clipboard text, file names, addresses and device names are removed.',
    ...section('App', appRows),
    ...section('Device', deviceRows),
    ...section('State', statusRows),
    ...section('Permissions', permissionRows),
    ...section('Updates', updateRows),
    ...section('Recent exits', exitRows),
    ...section(`Daemon log (last ${MAX_DAEMON_LOG_LINES})`, tail(data.daemonLog, MAX_DAEMON_LOG_LINES, '(empty)')),
    ...section(`App log (last ${MAX_APP_LOG_LINES})`, tail(data.appLog, MAX_APP_LOG_LINES, '(empty)')),
  ];

  return { text: lines.join('\n'), lines, summary: buildIssueSummary(data) };
}

/**
 * The short, structured part of the report that fits in a GitHub issue URL. It deliberately holds
 * no log lines and no free text at all: only enums, versions and numbers.
 */
export function buildIssueSummary(data: ReportData): string {
  const { app, device, status } = data;
  const relay = status.relay;
  const exits =
    Array.isArray(data.exits) && data.exits.length > 0
      ? data.exits
          .slice(0, 5)
          .map((e) => e.reason)
          .join(', ')
      : null;
  const rows = [
    `App: ${app.version} (build ${orDash(app.versionCode)}), channel ${orDash(app.channel)}, ${
      app.devBundle
        ? 'dev-server bundle'
        : app.embedded == null
          ? 'bundle unknown'
          : app.embedded
            ? 'embedded bundle'
            : 'OTA bundle'
    }`,
    `Device: ${[device.manufacturer, device.model].filter(Boolean).join(' ') || '—'}, Android ${orDash(device.osVersion)} (API ${orDash(device.apiLevel)})`,
    `Link: ${relay ? `${relay.status}${relay.transport ? ` via ${relay.transport}` : ''}, Mac ${relay.peerOnline ? 'online' : 'offline'}` : 'unknown'}`,
    `Capture: ${status.capture ? status.capture.state : 'unknown'}; daemon alive: ${yesNo(status.daemonAlive)}`,
    ...(exits ? [`Recent exits: ${exits}`] : []),
    'Full report: attach the file you shared from Settings ▸ Send diagnostics.',
  ];
  const text = rows.join('\n');
  return text.length <= MAX_SUMMARY ? text : text.slice(0, MAX_SUMMARY - 1) + '…';
}

/**
 * The prefilled "new issue" URL, carrying the summary TWICE on purpose:
 *  - `summary=` fills the Issue Form's field of that id (`.github/ISSUE_TEMPLATE/bug_report.yml`) in
 *    a browser;
 *  - `body=` is what the **GitHub Android app** reads. Checked on a device: that app opens its own
 *    plain "Create Issue" screen, ignores `template=` and every form-field id, and fills only the
 *    title and `body=` — so without it the summary was silently lost for anyone with the app installed.
 * (Whether a browser ignores `body=` when a form template is named has not been verified.)
 * Shrinks the summary until the URL fits, because GitHub answers an over-long query string with an
 * error page — and it is counted twice here.
 */
export function issueUrl(summary: string, title = '[Bug] '): string {
  let s = summary;
  for (;;) {
    const enc = encodeURIComponent(s);
    const url =
      `${NEW_ISSUE_URL}?template=bug_report.yml` +
      `&title=${encodeURIComponent(title)}&summary=${enc}&body=${enc}`;
    if (url.length <= MAX_ISSUE_URL || s.length === 0) return url;
    s = s.slice(0, Math.max(0, s.length - 200));
  }
}
