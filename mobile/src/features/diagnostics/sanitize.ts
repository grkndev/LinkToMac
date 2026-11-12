/**
 * Log sanitizer — the "at the boundary" half of the log-privacy rule.
 *
 * Nothing that leaves the app (Logs ▸ Share, Daemon Log ▸ Share, the Diagnostics report, a GitHub
 * issue body) may carry user data: clipboard text, file names, relay/LAN addresses, the Mac's or the
 * phone's name, installed-app package names, content URIs/paths, the pairing room or key.
 *
 * Why this is a best-effort net and not the whole defence: log lines are free text, so a new line
 * that interpolates something sensitive would sail straight past any pattern list. The other halves
 * are (a) not writing user data into log lines in the first place (native code logs lengths, counts
 * and states) and (b) letting the person read exactly what will be sent before they send it
 * (the Diagnostics preview). `scripts/check-log-privacy.mjs` guards (a).
 *
 * Pure and idempotent on purpose: `sanitizeLine(sanitizeLine(x)) === sanitizeLine(x)`. Every rule
 * only ever emits one of the PLACEHOLDERS, and no rule matches inside a placeholder. No imports, so
 * it runs under `bun test` with no React Native in sight.
 */

/** Everything the sanitizer substitutes. Kept in one place so rules and tests agree. */
export const PLACEHOLDERS = [
  '<clipboard text>',
  '<file>',
  '<path>',
  '<app>',
  '<host>',
  '<mac>',
  '<phone>',
  '<token>',
  '<redacted>',
] as const;

type MaybeString = string | null | undefined;

/**
 * Device-specific values that only exist at runtime (so no pattern can know them). Whatever shows
 * up in these lists is replaced wherever it appears in the text, case-insensitively.
 */
export interface KnownValues {
  /** The paired Mac's computer name → `<mac>`. */
  macNames?: readonly MaybeString[];
  /** This phone's device name → `<phone>`. */
  phoneNames?: readonly MaybeString[];
  /** Relay / LAN host names → `<host>`. */
  hosts?: readonly MaybeString[];
  /** Room id, E2E key, relay token, cert fingerprint → `<token>`. */
  secrets?: readonly MaybeString[];
}

/** Collects the known-sensitive values from the pairing, the relay config and the device. */
export function knownValuesFrom(src: {
  pairing?: { room?: MaybeString; key?: MaybeString; name?: MaybeString } | null;
  server?: {
    host?: MaybeString;
    token?: MaybeString;
    certFingerprint?: MaybeString;
    lanHost?: MaybeString;
  } | null;
  deviceName?: MaybeString;
}): KnownValues {
  const { pairing, server, deviceName } = src;
  return {
    macNames: [pairing?.name],
    phoneNames: [deviceName],
    hosts: [server?.host, server?.lanHost],
    secrets: [pairing?.room, pairing?.key, server?.token, server?.certFingerprint],
  };
}

// ── known values ─────────────────────────────────────────────────────────────────────────────

/** Shorter than this and a "known value" would shred ordinary words ("Mac", "S9"). */
const MIN_KNOWN_LENGTH = 3;

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Compiles the known values into one case-insensitive alternation, longest first so "Pixel 8 Pro"
 * wins over "Pixel 8". Values that are (part of) one of our own placeholders are dropped: a Mac
 * named "Mac" must not turn `<mac>` into `<<mac>>` on the second pass.
 */
function compileKnown(known: KnownValues | undefined): ((text: string) => string) | null {
  if (!known) return null;
  const groups: [readonly MaybeString[] | undefined, string][] = [
    [known.macNames, '<mac>'],
    [known.phoneNames, '<phone>'],
    [known.hosts, '<host>'],
    [known.secrets, '<token>'],
  ];
  const entries: { value: string; placeholder: string }[] = [];
  for (const [values, placeholder] of groups) {
    for (const raw of values ?? []) {
      const value = raw?.trim();
      if (!value || value.length < MIN_KNOWN_LENGTH) continue;
      const lower = value.toLowerCase();
      if (PLACEHOLDERS.some((p) => p.includes(lower))) continue;
      entries.push({ value, placeholder });
    }
  }
  if (entries.length === 0) return null;
  entries.sort((a, b) => b.value.length - a.value.length);
  const byLower = new Map<string, string>();
  for (const e of entries) if (!byLower.has(e.value.toLowerCase())) byLower.set(e.value.toLowerCase(), e.placeholder);
  const re = new RegExp(entries.map((e) => escapeRegExp(e.value)).join('|'), 'gi');
  return (text) => text.replace(re, (m) => byLower.get(m.toLowerCase()) ?? '<redacted>');
}

// ── patterns ─────────────────────────────────────────────────────────────────────────────────

// A URL/URI/path runs to the next space or bracket and must not END on punctuation, so
// "…/a.pdf: open failed" keeps its colon. It may also run THROUGH a placeholder: the known-value
// pass has usually already turned "bifrost.example" into "<host>" inside "wss://bifrost.example/ws".
const PH = '<[a-z ]+>';
const NOT_END = `(?:${PH}|[^\\s"'<>)\\]])*(?:${PH}|[^\\s"'<>)\\]:,.;])`;

// 1. clipboard lines — `clip [daemon]: <text>` (native) and `clip ⬆ "<text>"` (JS). A bare length
//    ("12 chars") is what source-side logging writes now and is kept.
const CLIP_NATIVE = /(\bclip \[[^\]\n]*\]: )(?!\d+ chars?\b)[^\n]*/g;
const CLIP_UP = /(\bclip ⬆ )(?!\(\d+ chars?\))[^\n]*/g;

// 2. file names
const SHARE_FILE = /(\bshare -> Mac file: ).+?( \(\d+ B\b)/g;
const SAVED_FILE = /(\bfile saved to Downloads: ).+?( \(\d+ B\))/g;
const NAME_PREFIX = /(\b(?:couldn't read|no access to|couldn't save) )([^\n]*)/g;
/** The ": " that ends a file name and starts an exception ("name.pdf: java.io.IOException…"). */
const EXCEPTION_SEP = /: (?=[\w.$]*(?:Exception|Error)\b)/;

// 3. e-mail, then addresses
const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/g;
const URL = new RegExp(`\\b(?:wss?|https?):\\/\\/${NOT_END}`, 'gi');
const RESOLVE_HOST = /(\bresolve host )"[^"\n]*"/gi;
const UNKNOWN_HOST = /(UnknownHostException: )[^\s:]+/g;
const IPV4 = /(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?(?!\w)(?!\.\d)/g;
const IPV6_COMPRESSED =
  /(?<![\w:])(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4})*)?::(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4})*)?(?:%\w+)?(?![\w:])/gi;
const IPV6_FULL = /(?<![\w:])(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}(?![\w:])/gi;
const HW_ADDRESS = /(?<![\w:])(?:[0-9a-f]{2}:){5}[0-9a-f]{2}(?![\w:])/gi;
const DOT_LOCAL = /(?<![\w.-])(?:[a-z0-9-]+\.)*[a-z0-9-]+\.local\b(?::\d{1,5})?/gi;
const HOST_PORT = /(?<![\w.-])(?:[a-z0-9-]+\.)+[a-z0-9-]+:\d{2,5}(?!\w)/gi;
/** `ClipBus.kt:84` looks like host:port but is a source location. */
const SOURCE_LOCATION = /\.(?:kt|java|ts|tsx|js|jsx|mjs|swift):\d+$/i;
/**
 * Loopback is this phone talking to itself (the clipboard daemon's bridge on 127.0.0.1:53125), not
 * anyone's address — and it is exactly what a "bridge can't reach the daemon" report needs to show.
 */
const LOOPBACK = /^(?:127\.\d{1,3}\.\d{1,3}\.\d{1,3}(?::\d{1,5})?|::1)$/;
const hideAddress = (m: string): string => (LOOPBACK.test(m) ? m : '<host>');

// 4. content URIs and file-system paths
const CONTENT_URI = new RegExp(`\\b(?:content|file):\\/\\/${NOT_END}`, 'gi');
const FS_PATH = new RegExp(
  `(?<![\\w<])\\/(?:storage|sdcard|mnt|proc|sys|system|cache|data\\/(?!local\\/tmp\\/))\\/?${NOT_END}`,
  'g',
);

// 5. package-name-like dotted identifiers (three or more segments, first one letters only so a
//    version such as "v0.12.1" is left alone). Our own and the platform's class names are allowed:
//    "java.io.FileNotFoundException" is exactly what a bug report needs.
const PACKAGE_LIKE = /(?<![\w./-])[a-z]{2,}(?:\.[a-z0-9_]+){2,}\b/gi;
const ALLOWED_PACKAGE =
  /^(?:(?:com\.grkndev\.linktomac|expo\.modules\.selfadb|org\.json|org\.conscrypt)(?![a-z0-9_])|(?:java|javax|android|androidx|kotlin|kotlinx|okhttp3|okio|dalvik|libcore)\.)/i;

// 6. phone numbers — only when they LOOK like one ("+90 555 123 45 67", "(555) 123-4567"): a plain
//    run of digits is far more likely a byte count or a versionCode, which a bug report needs.
const PHONE_PLUS = /(?<![\w+])\+\d[\d\s().-]{5,}\d(?!\w)/g;
const PHONE_FORMATTED = /(?<![\w.-])\(?\d{2,4}\)?[\s.-]\d{3}[\s.-]\d{2,4}(?:[\s.-]\d{2,4})?(?![\w.-])/g;

// 7. long opaque tokens: hex digests, base64 keys, UUIDs. A run needs a digit, otherwise it is a
//    camel-case class name ("ForegroundServiceStartNotAllowedException").
const LONG_TOKEN = /[A-Za-z0-9+/_-]{24,}={0,2}/g;

function stripFileName(_m: string, prefix: string, rest: string): string {
  const i = rest.search(EXCEPTION_SEP);
  return `${prefix}<file>${i >= 0 ? rest.slice(i) : ''}`;
}

function sanitizeWith(line: string, known: ((text: string) => string) | null): string {
  let s = line;
  if (known) s = known(s);

  s = s.replace(CLIP_NATIVE, '$1<clipboard text>').replace(CLIP_UP, '$1<clipboard text>');

  s = s
    .replace(SHARE_FILE, '$1<file>$2')
    .replace(SAVED_FILE, '$1<file>$2')
    .replace(NAME_PREFIX, stripFileName);

  s = s.replace(EMAIL, '<redacted>');

  s = s
    .replace(URL, '<host>')
    .replace(RESOLVE_HOST, '$1"<host>"')
    .replace(UNKNOWN_HOST, '$1<host>')
    .replace(HW_ADDRESS, '<redacted>')
    .replace(IPV4, hideAddress)
    .replace(IPV6_FULL, '<host>')
    .replace(IPV6_COMPRESSED, hideAddress)
    .replace(DOT_LOCAL, '<host>')
    .replace(HOST_PORT, (m) => (SOURCE_LOCATION.test(m) || LOOPBACK.test(m) ? m : '<host>'));

  s = s.replace(CONTENT_URI, '<path>').replace(FS_PATH, '<path>');

  s = s.replace(PACKAGE_LIKE, (m) => (ALLOWED_PACKAGE.test(m) ? m : '<app>'));

  s = s.replace(PHONE_PLUS, '<redacted>').replace(PHONE_FORMATTED, '<redacted>');

  s = s.replace(LONG_TOKEN, (m) => (/\d/.test(m) ? '<token>' : m));

  return s;
}

/** Sanitizes one log line. Idempotent. */
export function sanitizeLine(line: string, known?: KnownValues): string {
  return sanitizeWith(line, compileKnown(known));
}

/** Sanitizes many lines, compiling the known values once. */
export function sanitizeLines(lines: readonly string[], known?: KnownValues): string[] {
  const compiled = compileKnown(known);
  return lines.map((l) => sanitizeWith(l, compiled));
}

/** Sanitizes a multi-line blob (the daemon log arrives as one string). */
export function sanitizeText(text: string, known?: KnownValues): string {
  return sanitizeLines(text.split('\n'), known).join('\n');
}
