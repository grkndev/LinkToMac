#!/usr/bin/env node
/**
 * Log-privacy guard — the "at the source" half of the rule (the other half is the boundary
 * sanitizer in src/features/diagnostics/sanitize.ts).
 *
 * Rule: a log call must not interpolate user data. It may log lengths, counts, states and
 * exception CLASS names, but not clipboard text, file names, addresses, package names, URIs/paths,
 * or the pairing secrets. `e.message` is deliberately NOT banned: it is free text that the
 * sanitizer cleans on the way out, and banning it would blind the logs to real failures.
 *
 * What it scans: the arguments of `ClipBus.log(` / `log(` in the Kotlin module and the daemon's
 * Java, and of `console.*(` / the Logs screen's `append(` in the app's TypeScript. Only the CODE
 * inside a call counts — literal text ("no text on the clipboard") never triggers it; Kotlin/TS
 * interpolations (`$x`, `${…}`, including nested strings) do, and so do `+` concatenations.
 *
 * Escape hatch: put `log-privacy: ok` in a comment on the call's first or last line, with a reason.
 *
 *   node scripts/check-log-privacy.mjs        # exit 1 and a list when something leaks
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

/** Variable/property names that hold user data. Matched as whole words inside a log call's code. */
export const FORBIDDEN = [
  'name', 'display', 'text', 'body', 'title', 'artist', 'album',
  'url', 'relayUrl', 'host', 'pairHost', 'connHost', 'addr', 'address',
  'pkg', 'srcPkg', 'packageName', 'uri', 'path', 'authority', 'getAuthority',
  'room', 'key', 'token', 'secret', 'password',
  'peerName', 'macName', 'deviceName',
];

const FORBIDDEN_RE = new RegExp(`\\b(${FORBIDDEN.join('|')})\\b`, 'g');
/**
 * `text.length`, `uri?.isEmpty()`, `secret != null` … : asking about the data without printing it
 * is fine.
 */
const SAFE_USE =
  /^\s*(?:(?:\?|!!)?\.(?:length|size|count|isEmpty|isBlank|isNotEmpty|isNullOrEmpty)\b|(?:!=|==)=?\s*null\b)/;
const ESCAPE = 'log-privacy: ok';

// ── a tiny tokenizer: pull the CODE out of a call, skipping literal text, keeping interpolations ──

function readString(src, i, quote, lang) {
  let j = i + 1;
  const frags = [];
  while (j < src.length) {
    const ch = src[j];
    if (ch === '\\') { j += 2; continue; }
    if (ch === quote) return { end: j + 1, frags };
    const interpolates = (lang === 'kt') || (lang === 'ts' && quote === '`');
    if (interpolates && ch === '$' && src[j + 1] === '{') {
      const r = readBraced(src, j + 2, lang);
      frags.push(...r.frags);
      j = r.end;
      continue;
    }
    if (lang === 'kt' && ch === '$' && /[A-Za-z_]/.test(src[j + 1] ?? '')) {
      const m = /^[A-Za-z_]\w*/.exec(src.slice(j + 1));
      frags.push(m[0]);
      j += 1 + m[0].length;
      continue;
    }
    j++;
  }
  return { end: j, frags };
}

function readBraced(src, i, lang) {
  let depth = 1;
  let code = '';
  const frags = [];
  let j = i;
  while (j < src.length) {
    const ch = src[j];
    if (ch === '"' || (ch === '`' && lang === 'ts')) {
      const r = readString(src, j, ch, lang);
      frags.push(...r.frags);
      j = r.end;
      continue;
    }
    if (ch === "'") { j = skipChar(src, j); continue; }
    if (ch === '{') depth++;
    if (ch === '}') {
      depth--;
      if (depth === 0) { j++; break; }
    }
    code += ch;
    j++;
  }
  frags.push(code);
  return { end: j, frags };
}

function skipChar(src, i) {
  let j = i + 1;
  while (j < src.length && src[j] !== "'") j += src[j] === '\\' ? 2 : 1;
  return j + 1;
}

/** Reads the argument list that starts right after a call's `(`; returns its code fragments. */
function readCall(src, openIdx, lang) {
  let depth = 1;
  let code = '';
  const frags = [];
  let j = openIdx;
  while (j < src.length) {
    const ch = src[j];
    if (ch === '"' || (ch === '`' && lang === 'ts')) {
      const r = readString(src, j, ch, lang);
      frags.push(...r.frags);
      j = r.end;
      continue;
    }
    if (ch === "'") { j = skipChar(src, j); continue; }
    if (ch === '(') depth++;
    if (ch === ')') {
      depth--;
      if (depth === 0) { j++; break; }
    }
    code += ch;
    j++;
  }
  frags.push(code);
  return { end: j, frags };
}

function leaks(frags) {
  const found = new Set();
  for (const f of frags) {
    for (const m of f.matchAll(FORBIDDEN_RE)) {
      if (!SAFE_USE.test(f.slice(m.index + m[0].length))) found.add(m[0]);
    }
  }
  return [...found];
}

const lineOf = (src, idx) => src.slice(0, idx).split('\n').length;

function inComment(src, idx) {
  const lineStart = src.lastIndexOf('\n', idx - 1) + 1;
  const before = src.slice(lineStart, idx);
  return /^\s*(\/\/|\*|\/\*)/.test(before) || before.includes('//');
}

const CALLS = {
  // `log(` / `ClipBus.log(` — not `.log(`-on-something-else, not `catalog(`, `logRetry(`.
  kt: /(?<![\w.])(?:ClipBus\.)?log\(/g,
  java: /(?<![\w.])log\(/g,
  // The Logs screen's append(), and any console call.
  ts: /(?<![\w.])append\(|\bconsole\.(?:log|info|warn|error|debug)\(/g,
};

/**
 * Finds log calls that interpolate user data. `lang` is 'kt' | 'java' | 'ts'.
 * Returns [{ line, names, snippet }].
 */
export function findViolations(src, lang) {
  const out = [];
  for (const m of src.matchAll(CALLS[lang])) {
    if (inComment(src, m.index)) continue;
    const { end, frags } = readCall(src, m.index + m[0].length, lang);
    const names = leaks(frags);
    if (names.length === 0) continue;
    const firstLineStart = src.lastIndexOf('\n', m.index - 1) + 1;
    const lastLineEnd = src.indexOf('\n', end) === -1 ? src.length : src.indexOf('\n', end);
    const span = src.slice(firstLineStart, lastLineEnd);
    if (span.includes(ESCAPE)) continue;
    out.push({ line: lineOf(src, m.index), names, snippet: src.slice(m.index, end).replace(/\s+/g, ' ').slice(0, 140) });
  }
  return out;
}

// ── file walking (only when run as a script) ─────────────────────────────────────────────────

function walk(dir, exts) {
  const files = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) files.push(...walk(p, exts));
    else if (exts.some((e) => name.endsWith(e))) files.push(p);
  }
  return files;
}

function main() {
  const root = join(dirname(fileURLToPath(import.meta.url)), '..');
  const targets = [
    ...walk(join(root, 'modules/selfadb/android/src/main/java'), ['.kt']).map((f) => [f, 'kt']),
    [join(root, 'native-src/clipboard-agent/ClipboardAgent.java'), 'java'],
    ...walk(join(root, 'src'), ['.ts', '.tsx'])
      .filter((f) => !/\.test\.tsx?$/.test(f))
      .map((f) => [f, 'ts']),
  ];

  let total = 0;
  for (const [file, lang] of targets) {
    for (const v of findViolations(readFileSync(file, 'utf8'), lang)) {
      total++;
      console.error(`${relative(root, file)}:${v.line}  logs ${v.names.join(', ')}\n    ${v.snippet}`);
    }
  }
  if (total > 0) {
    console.error(
      `\n${total} log call(s) interpolate user data. Log a length, count or state instead ` +
        `(or, with a reason, add "${ESCAPE}" to the call's line). See TECHNICAL.md ▸ Security.`,
    );
    process.exit(1);
  }
  console.log(`log-privacy: ${targets.length} files clean`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main();
