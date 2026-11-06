#!/usr/bin/env node
// Generates the flow diagrams used by README.md and TECHNICAL.md.
//
//   node docs/diagrams/build.mjs            # writes docs/images/*.svg and renders *.png
//   node docs/diagrams/build.mjs --svg-only # skip the PNG step (no browser needed)
//
// Why PNG as well as SVG: GitHub draws an <img> SVG with the *viewer's* fonts, so text can overflow
// its box on another machine. The PNG (rendered at 2x by a Chromium in headless mode) is pixel-stable
// at every screen size and scales down uniformly. The docs embed the PNG; the SVG stays as the
// editable source. Edit a diagram here, re-run, commit both files.
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const OUT = join(here, '..', 'images');
mkdirSync(OUT, { recursive: true });

// ───────────────────────────── theme ─────────────────────────────
const C = {
  bg: '#10151C',
  frame: '#2A323D',
  node: '#171D26',
  nodeStroke: '#313B49',
  text: '#E8EEF5',
  muted: '#93A0B1',
  code: '#9CCBFF',
  arrow: '#7B8899',
  phone: '#3DDC97', // Android side
  mac: '#59B8FF', // macOS side
  relay: '#F2B84B', // relay / cloud / warnings
  ble: '#B696F5', // Bluetooth + decisions
};
const SANS = `-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif`;
const MONO = `ui-monospace, 'SF Mono', Menlo, Consolas, monospace`;

// ───────────────────────────── svg helpers ─────────────────────────────
// Size note: GitHub shows these at ~830 px wide, so every canvas is ~1100 px wide and the text is
// large relative to it. Don't widen a canvas without growing the type, or it stops being readable.
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** `backticks` switch to the mono/code style inside a text run. */
const rich = (s) =>
  s
    .split('`')
    .map((p, i) =>
      i % 2
        ? `<tspan font-family="${MONO}" font-size="0.93em" fill="${C.code}">${esc(p)}</tspan>`
        : esc(p),
    )
    .join('');

const LH = 27; // detail-line pitch
/** Box height for a node with n detail lines (left-aligned layout). */
const nodeH = (n) => 36 + (n ? 31 + LH * (n - 1) : 0) + 24;

class Svg {
  constructor(w, h) {
    this.w = w;
    this.h = h;
    this.body = [];
    this.markers = new Map();
  }
  add(s) {
    this.body.push(s);
  }
  marker(color) {
    if (!this.markers.has(color)) this.markers.set(color, `m${this.markers.size}`);
    return this.markers.get(color);
  }
  rect(x, y, w, h, { fill = C.node, stroke = C.nodeStroke, sw = 1.8, r = 14, dash } = {}) {
    this.add(
      `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r}" fill="${fill}" stroke="${stroke}" stroke-width="${sw}"${dash ? ` stroke-dasharray="${dash}"` : ''}/>`,
    );
  }
  text(x, y, str, { size = 17.5, weight = 400, fill = C.text, anchor = 'start', mono = false, ls } = {}) {
    this.add(
      `<text x="${x}" y="${y}" font-family="${mono ? MONO : SANS}" font-size="${size}" font-weight="${weight}" fill="${fill}" text-anchor="${anchor}"${ls ? ` letter-spacing="${ls}"` : ''}>${rich(str)}</text>`,
    );
  }
  /** A titled box with muted detail lines. */
  node(x, y, w, h, { title, lines = [], accent, fill, dash, tsize = 21, lsize = 17.5, center = false } = {}) {
    this.rect(x, y, w, h, { fill, stroke: accent ?? C.nodeStroke, dash, sw: accent ? 2.2 : 1.8 });
    const n = lines.length;
    let base;
    if (center) {
      const block = tsize * 0.8 + (n ? 31 + LH * (n - 1) + 5 : 5);
      base = y + (h - block) / 2 + tsize * 0.8;
    } else base = y + 36;
    const ax = center ? x + w / 2 : x + 20;
    const anchor = center ? 'middle' : 'start';
    if (title) this.text(ax, base, title, { size: tsize, weight: 650, fill: accent ?? C.text, anchor });
    lines.forEach((l, i) => this.text(ax, base + 31 + LH * i, l, { size: lsize, fill: C.muted, anchor }));
  }
  /** Rounded orthogonal polyline with an arrowhead (and optionally one at the start). */
  arrow(pts, { color = C.arrow, dash, sw = 2.6, both = false, head = true, r = 16 } = {}) {
    const id = this.marker(color);
    let d = `M${pts[0][0]} ${pts[0][1]}`;
    for (let i = 1; i < pts.length - 1; i++) {
      const [px, py] = pts[i - 1], [cx, cy] = pts[i], [nx, ny] = pts[i + 1];
      const l1 = Math.hypot(cx - px, cy - py), l2 = Math.hypot(nx - cx, ny - cy);
      const rr = Math.min(r, l1 / 2, l2 / 2);
      const ax = cx - ((cx - px) / l1) * rr, ay = cy - ((cy - py) / l1) * rr;
      const bx = cx + ((nx - cx) / l2) * rr, by = cy + ((ny - cy) / l2) * rr;
      d += ` L${ax} ${ay} Q${cx} ${cy} ${bx} ${by}`;
    }
    d += ` L${pts.at(-1)[0]} ${pts.at(-1)[1]}`;
    this.add(
      `<path d="${d}" fill="none" stroke="${color}" stroke-width="${sw}" stroke-linecap="round"${dash ? ` stroke-dasharray="${dash}"` : ''}${head ? ` marker-end="url(#${id})"` : ''}${both ? ` marker-start="url(#${id})"` : ''}/>`,
    );
  }
  /** A label that sits on top of a line (the line is masked behind it). */
  pill(cx, cy, str, { color = C.muted, size = 15.5, fill = C.bg } = {}) {
    const plain = str.replace(/`/g, '');
    const w = Math.round(plain.length * size * 0.56 + 24);
    const h = size + 14;
    this.rect(cx - w / 2, cy - h / 2, w, h, { fill, stroke: 'none', sw: 1, r: h / 2 });
    this.text(cx, cy + size * 0.35, str, { size, fill: color, anchor: 'middle' });
  }
  /** A small rounded chip. */
  chip(x, y, w, h, str, { accent, size = 16.5, fill = C.node } = {}) {
    this.rect(x, y, w, h, { fill, stroke: accent ?? C.nodeStroke, r: h / 2, sw: 1.6 });
    this.text(x + w / 2, y + h / 2 + size * 0.35, str, { size, anchor: 'middle', fill: C.text });
  }
  toString() {
    this.h = Math.ceil(this.h);
    this.w = Math.ceil(this.w);
    const defs = [...this.markers]
      .map(
        ([color, id]) =>
          `<marker id="${id}" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="${color}"/></marker>`,
      )
      .join('');
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${this.w}" height="${this.h}" viewBox="0 0 ${this.w} ${this.h}">
<defs>${defs}</defs>
<rect x="1" y="1" width="${this.w - 2}" height="${this.h - 2}" rx="20" fill="${C.bg}" stroke="${C.frame}" stroke-width="2"/>
${this.body.join('\n')}
</svg>
`;
  }
}

/** A large labelled container (the "Android phone" / "macOS" frames). */
function frame(s, x, y, w, h, label, accent) {
  s.rect(x, y, w, h, { fill: 'none', stroke: accent, sw: 1.8, r: 18 });
  s.text(x + 20, y + 32, label, { size: 14.5, weight: 700, fill: accent, ls: '1.6' });
}

// ───────────────────────────── diagrams ─────────────────────────────
const diagrams = {};

// 1 ── README: the big picture ───────────────────────────────────────
diagrams['how-it-works'] = () => {
  const s = new Svg(1100, 470);
  const top = 125, h = nodeH(4), mid = top + h / 2;
  const phone = { x: 30, w: 310 }, relay = { x: 425, w: 250 }, mac = { x: 760, w: 310 };

  s.node(phone.x, top, phone.w, h, {
    accent: C.phone,
    title: 'Android phone',
    lines: ['Background app', 'clipboard · lock · battery', 'notifications · SMS', 'files & share sheet'],
  });
  s.node(relay.x, top, relay.w, h, {
    accent: C.relay,
    title: 'Your relay',
    lines: ['optional, self-hosted', 'tiny WebSocket server', 'routes by room id', 'sees only ciphertext'],
  });
  s.node(mac.x, top, mac.w, h, {
    accent: C.mac,
    title: 'Mac',
    lines: ['Menu-bar app + dashboard', 'clipboard · lock · QR', 'notifications · messages', 'files & drag-and-drop'],
  });

  // away from home: through the relay
  s.arrow([[phone.x + phone.w, mid], [relay.x, mid]], { both: true, color: C.relay });
  s.arrow([[relay.x + relay.w, mid], [mac.x, mid]], { both: true, color: C.relay });
  s.pill((phone.x + phone.w + relay.x) / 2, mid - 26, 'away', { color: C.relay });
  s.pill((relay.x + relay.w + mac.x) / 2, mid - 26, 'away', { color: C.relay });

  // same Wi-Fi: straight over the top
  const lanY = 55;
  const pc = phone.x + phone.w / 2, mc = mac.x + mac.w / 2;
  s.arrow([[pc, top], [pc, lanY], [mc, lanY], [mc, top]], { both: true, color: C.phone, dash: '9 7' });
  s.pill(550, lanY, 'Same Wi-Fi: direct LAN link, no relay', { color: C.phone, size: 17 });

  // Bluetooth: straight under the bottom
  const bleY = top + h + 70;
  s.arrow([[pc, top + h], [pc, bleY], [mc, bleY], [mc, top + h]], { both: true, color: C.ble, dash: '3 7' });
  s.pill(550, bleY, 'Bluetooth beacon: proximity auto-lock, local', { color: C.ble, size: 17 });

  s.text(550, bleY + 62, 'Clipboard, files, messages and the lock command are end-to-end encrypted.', { size: 16, fill: C.muted, anchor: 'middle' });
  return s;
};

// 2 ── TECHNICAL §1: component architecture ──────────────────────────
diagrams['architecture'] = () => {
  const s = new Svg(1100, 890);
  const P = { x: 20, y: 90, w: 410 };
  const M = { x: 660, y: 90, w: 410 };
  const h2 = nodeH(2), h3 = nodeH(3);
  const r1 = 145, r2 = r1 + h2 + 80, r3 = r2 + h3 + 80, bottom = r3 + h3 + 35;
  const ch = bottom - P.y;
  frame(s, P.x, P.y, P.w, ch, 'ANDROID (PHONE)', C.phone);
  frame(s, M.x, M.y, M.w, ch, 'MACOS', C.mac);

  // phone column
  const bx = P.x + 16, bw = P.w - 32, bc = bx + bw / 2;
  s.node(bx, r1, bw, h2, { title: 'Expo / React Native app', lines: ['UI, pairing, settings, Files', 'drives native via the Expo module'] });
  s.node(bx, r2, bw, h3, {
    accent: C.phone,
    title: 'Foreground Service (Kotlin)',
    lines: ['OkHttp WS → relay / LAN-direct', '`ClipBridge` (localhost client)', '`BleAdvertiser` (beacon)'],
  });
  s.node(bx, r3, bw, h3, {
    title: 'ClipboardAgent (shell UID)',
    lines: ['`app_process` daemon', '`IClipboard` reflection', '`ServerSocket` NDJSON'],
  });
  s.arrow([[bc, r1 + h2], [bc, r2]], {});
  s.pill(bc + 85, r1 + h2 + 40, 'Expo module', {});
  s.arrow([[bc, r2 + h3], [bc, r3]], { both: true });
  s.pill(bc + 105, r2 + h3 + 40, '127.0.0.1:53123', {});

  // relay in the middle
  const rc = r2 + h3 / 2;
  s.node(480, rc - 65, 130, 130, { accent: C.relay, title: 'Relay', lines: ['Node `ws`', 'room routing'], center: true, tsize: 20, lsize: 16 });
  ['Forwards opaque', 'frames by room id.', 'No storage,', 'no decryption.'].forEach((t, i) =>
    s.text(545, rc + 100 + i * 22, t, { size: 15, fill: C.muted, anchor: 'middle' }),
  );
  s.arrow([[bx + bw, rc], [480, rc]], { both: true, color: C.relay });

  // mac column
  const mx = M.x + 16, mw = M.w - 32, mc = mx + mw / 2;
  s.node(mx, r1, mw, h2, { title: 'Clipboard', lines: ['`NSPasteboard` poll', 'text and images'] });
  s.node(mx, r2, mw, h3, {
    accent: C.mac,
    title: 'Network',
    lines: ['`URLSession` WS client → relay', 'LAN WS server (`NWListener`)', 'advertised over Bonjour'],
  });
  s.node(mx, r3, mw, h3, {
    title: 'Proximity & system',
    lines: ['`CoreBluetooth` central', '`SACLockScreen` · pairing QR', 'Keychain · Sparkle'],
  });
  s.arrow([[610, rc], [mx, rc]], { both: true, color: C.relay });

  // LAN-direct over the top, BLE under the bottom
  s.arrow([[bc, P.y], [bc, 45], [mc, 45], [mc, M.y]], { both: true, color: C.phone, dash: '9 7' });
  s.pill(545, 45, 'Same Wi-Fi: LAN-direct, no relay', { color: C.phone, size: 17 });
  const bleY = bottom + 75;
  s.arrow([[bc, bottom], [bc, bleY], [mc, bleY], [mc, bottom]], { both: true, color: C.ble, dash: '3 7' });
  s.pill(545, bleY, 'BLE beacon: proximity auto-lock, local', { color: C.ble, size: 17 });
  s.h = bleY + 45;
  return s;
};

// 3 ── TECHNICAL §3: the Self-ADB layers ─────────────────────────────
diagrams['self-adb-layers'] = () => {
  const s = new Svg(1110, 0);
  const L = { x: 30, w: 450 }, R = { x: 630, w: 450 };
  const h1 = nodeH(1), h2 = nodeH(2), h3 = nodeH(3);
  const y1 = 40, y2 = y1 + h1 + 90, y3 = y2 + h1 + 90, y4 = y3 + h2 + 90;

  s.node(L.x, y1, L.w, h1, { title: 'Expo module', lines: ['control plane, alive only with JS'] });
  s.node(L.x, y2, L.w, h1, { title: '`libadb-android`', lines: ['pure-Java ADB client (adb-over-TLS)'] });
  s.node(R.x, y2, R.w, h1, { accent: C.phone, title: 'On-device `adbd`', lines: ['Wireless Debugging'] });
  s.node(L.x, y3, L.w, h2, { title: '`app_process`', lines: ['shell-side launcher'] });
  s.node(R.x, y3, R.w, h2, { accent: C.phone, title: 'ClipboardAgent', lines: ['shell UID, detached daemon', '`ServerSocket`, survives the app'] });
  s.node(L.x, y4, L.w, h3, {
    accent: C.phone,
    title: 'ClipForegroundService',
    lines: ['owns `ClipBridge` (localhost client),', '`RelayClient` (WS), `BleAdvertiser`', 'survives an app swipe (`START_STICKY`)'],
  });

  const lc = L.x + L.w / 2;
  s.arrow([[lc, y1 + h1], [lc, y2]], {});
  s.pill(lc + 135, y1 + h1 + 45, 'start / pair / deploy / kill', {});
  s.arrow([[L.x + L.w, y2 + h1 / 2], [R.x, y2 + h1 / 2]], { color: C.phone });
  s.pill((L.x + L.w + R.x) / 2, y2 + h1 / 2, 'TLS + spake2', { color: C.phone });
  s.arrow([[lc, y2 + h1], [lc, y3]], {});
  s.pill(lc + 115, y2 + h1 + 45, 'exec / push streams', {});
  s.arrow([[L.x + L.w, y3 + h2 / 2], [R.x, y3 + h2 / 2]], { color: C.phone });
  s.pill((L.x + L.w + R.x) / 2, y3 + h2 / 2, 'launches', { color: C.phone });
  const ax = R.x + R.w / 2, ay = y4 + h3 / 2;
  s.arrow([[ax, y3 + h2], [ax, ay], [L.x + L.w, ay]], { both: true, color: C.phone });
  s.pill((L.x + L.w + ax) / 2, ay, '127.0.0.1:53123 · NDJSON', { color: C.phone });

  s.text(R.x, y1 + 38, 'CONTROL PLANE', { size: 14.5, weight: 700, fill: C.muted, ls: '1.6' });
  s.text(R.x, y1 + 66, 'Pairs, deploys and kills the', { size: 16.5, fill: C.muted });
  s.text(R.x, y1 + 90, 'daemon over ADB.', { size: 16.5, fill: C.muted });
  s.text(R.x, ay + 75, 'DATA PLANE', { size: 14.5, weight: 700, fill: C.muted, ls: '1.6' });
  s.text(R.x, ay + 103, 'Runs with no ADB and no JS', { size: 16.5, fill: C.muted });
  s.text(R.x, ay + 127, 'once the daemon is up.', { size: 16.5, fill: C.muted });
  s.h = Math.max(y4 + h3, ay + 127) + 40;
  return s;
};

// 4 ── TECHNICAL §3.6: autoStart decision flow ───────────────────────
diagrams['autostart-flow'] = () => {
  const s = new Svg(1110, 0);
  const X = 30, W = 440, OX = 790, OW = 290, GAP = 70;
  const cx = X + W / 2;
  const hs = { poll: nodeH(1), alive: nodeH(1), paired: 84, wd: nodeH(1), mdns: 84, connect: nodeH(1), deploy: nodeH(2), ready: 84 };
  const row = {};
  let y = 40;
  for (const k of Object.keys(hs)) {
    row[k] = y;
    y += hs[k] + GAP;
  }

  const step = (k, title, lines = [], o = {}) => s.node(X, row[k], W, hs[k], { title, lines, center: true, ...o });
  const out = (k, title, sub, accent) => s.node(OX, row[k], OW, hs[k], { title, lines: sub ? [sub] : [], accent, center: true });
  const down = (a, b, label) => {
    s.arrow([[cx, row[a] + hs[a]], [cx, row[b]]], {});
    if (label) s.pill(cx, row[a] + hs[a] + GAP / 2, label, {});
  };
  const right = (k, label, color) => {
    const yy = row[k] + hs[k] / 2;
    s.arrow([[X + W, yy], [OX, yy]], { color });
    s.pill((X + W + OX) / 2, yy, label, { color });
  };

  step('poll', 'Poll `daemonAlive`', ['up to 2.4 s grace window (issue #29)']);
  step('alive', 'Daemon alive and healthy?', ['secret known, bridge not flapping'], { accent: C.ble });
  out('alive', '“ready”', 'no ADB needed', C.phone);
  step('paired', '`isPaired()`?', [], { accent: C.ble });
  out('paired', '“need-pair”', 'send the user to pairing', C.relay);
  step('wd', 'Self-enable Wireless Debugging', ['only if `WRITE_SECURE_SETTINGS` is held']);
  step('mdns', 'mDNS discover `_adb-tls-connect`');
  out('mdns', '“need-connect”', null, C.relay);
  step('connect', 'Drop stale session, then connect', ['`isConnected` → `disconnect`, connect']);
  out('connect', '“need-pair”', 're-pair gate', C.relay);
  step('deploy', 'Deploy and start', ['push the dex if needed, launch the daemon,', 'then start the service']);
  s.node(cx - 150, row.ready, 300, hs.ready, { title: '“ready”', accent: C.phone, center: true });

  down('poll', 'alive');
  right('alive', 'yes', C.phone);
  down('alive', 'paired', 'no: still dead after the grace window');
  right('paired', 'no', C.relay);
  down('paired', 'wd', 'yes');
  down('wd', 'mdns');
  right('mdns', 'not found', C.relay);
  down('mdns', 'connect', 'found');
  right('connect', 'AdbPairingRequiredException', C.relay);
  down('connect', 'deploy', 'ok');
  down('deploy', 'ready');
  s.h = row.ready + hs.ready + 40;
  return s;
};

// 5 ── TECHNICAL §3.9: Android self-update ───────────────────────────
diagrams['app-update-flow'] = () => {
  const s = new Svg(1100, 0);
  const BX = 110, BW = 960, BC = 60, TX = BX + 22; // box x/width, badge column x, text x
  const defs = [
    { h: nodeH(4) - 0, n: '', title: 'Trigger', accent: C.mac },
    { h: nodeH(1), n: '1', title: 'Check' },
    { h: nodeH(2), n: '2', title: 'Download' },
    { h: 202, n: '3', title: 'Verify' },
    { h: nodeH(2), n: '4', title: 'Ready', accent: C.phone },
    { h: 200, n: '5', title: 'Install' },
    { h: nodeH(2), n: '6', title: 'The OS replaces the app', accent: C.relay },
  ];
  let yy = 40;
  const st = defs.map((d) => {
    const o = { ...d, y: yy };
    yy += d.h + 50;
    return o;
  });
  const cys = st.map((b) => {
    const cy = b.y + 30;
    s.add(`<circle cx="${BC}" cy="${cy}" r="24" fill="${C.node}" stroke="${b.accent ?? C.nodeStroke}" stroke-width="2"/>`);
    if (b.n) s.text(BC, cy + 7, b.n, { size: 20, weight: 700, anchor: 'middle', fill: b.accent ?? C.text });
    else s.add(`<path d="M${BC - 6} ${cy - 10} L${BC + 11} ${cy} L${BC - 6} ${cy + 10} Z" fill="${b.accent}"/>`);
    return cy;
  });
  for (let i = 0; i < st.length - 1; i++) s.arrow([[BC, cys[i] + 24], [BC, cys[i + 1] - 24]], {});

  const box = (i, lines) => {
    const b = st[i];
    s.node(BX, b.y, BW, b.h, { title: b.title, lines, accent: b.accent });
    return b;
  };
  box(0, [
    '`ClipForegroundService` calls `schedule()` → `AppUpdater`',
    '(or the JS `checkAppUpdate`, or an app launch)',
    'First check ~60 s after start, then every 6 h.',
    'One retry after 15 min if the probe failed.',
  ]);
  box(1, ['`GET releases/latest`: newer than the installed `versionName`?']);
  box(2, ['To `cacheDir/updates/<v>.apk.part`', '(OkHttp, Range-resumed, progress → `onAppUpdate`)']);
  {
    const b = box(3, ['Rename the finished file, then check all of:']);
    const y1 = b.y + 88, y2 = y1 + 52;
    s.chip(TX, y1, 270, 40, 'SHA-256 (asset `digest`)');
    s.chip(TX + 284, y1, 170, 40, 'same package');
    s.chip(TX + 468, y1, 250, 40, 'higher `versionCode`');
    s.chip(TX, y2, 520, 40, 'signing certificate shared with the installed app');
  }
  box(4, ['`UpdateNotifier`: “Update ready, tap to install”', '(or the sheet’s Install button)']);
  {
    const b = box(5, []);
    const y1 = b.y + 62, y2 = y1 + 78;
    s.chip(TX, y1, 190, 40, '`InstallActivity`');
    s.arrow([[TX + 194, y1 + 20], [TX + 232, y1 + 20]], { sw: 2.2 });
    s.chip(TX + 236, y1, 380, 40, 'Install unknown apps (first time only)', { accent: C.relay });
    const ex = TX + 236 + 190, cx2 = TX + 150;
    s.arrow([[ex, y1 + 42], [ex, y1 + 59], [cx2, y1 + 59], [cx2, y2 - 2]], { sw: 2.2 });
    s.chip(TX, y2, 300, 40, '`PackageInstaller` session');
    s.arrow([[TX + 304, y2 + 20], [TX + 342, y2 + 20]], { sw: 2.2 });
    s.chip(TX + 346, y2, 270, 40, 'system “Update” screen');
  }
  box(6, ['`PackageReplacedReceiver`: `reset()` the record and files,', 'then restarts `ClipForegroundService`.']);
  s.h = yy - 50 + 40;
  return s;
};

// ───────────────────────────── build ─────────────────────────────
const svgOnly = process.argv.includes('--svg-only');
const BROWSERS = [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
];
const browser = BROWSERS.find((p) => spawnSync('test', ['-x', p]).status === 0);

for (const [name, make] of Object.entries(diagrams)) {
  const s = make();
  s.h = Math.ceil(s.h);
  const svgPath = join(OUT, `${name}.svg`);
  writeFileSync(svgPath, s.toString());
  let note = 'svg';
  if (!svgOnly) {
    if (!browser) {
      console.error('No Chromium-based browser found; re-run with --svg-only or install one.');
      process.exit(1);
    }
    const pngPath = join(OUT, `${name}.png`);
    const r = spawnSync(
      browser,
      [
        '--headless=new', '--disable-gpu', '--hide-scrollbars',
        '--default-background-color=00000000',
        '--force-device-scale-factor=2',
        `--window-size=${s.w},${s.h}`,
        `--screenshot=${pngPath}`,
        `file://${svgPath}`,
      ],
      { encoding: 'utf8' },
    );
    if (r.status !== 0) {
      console.error(r.stderr);
      process.exit(1);
    }
    note = 'svg + png';
  }
  console.log(`${name.padEnd(18)} ${s.w}x${s.h}  ${note}`);
}
