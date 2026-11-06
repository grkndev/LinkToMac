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
  rect(x, y, w, h, { fill = C.node, stroke = C.nodeStroke, sw = 1.5, r = 12, dash } = {}) {
    this.add(
      `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r}" fill="${fill}" stroke="${stroke}" stroke-width="${sw}"${dash ? ` stroke-dasharray="${dash}"` : ''}/>`,
    );
  }
  text(x, y, str, { size = 15, weight = 400, fill = C.text, anchor = 'start', mono = false, ls } = {}) {
    this.add(
      `<text x="${x}" y="${y}" font-family="${mono ? MONO : SANS}" font-size="${size}" font-weight="${weight}" fill="${fill}" text-anchor="${anchor}"${ls ? ` letter-spacing="${ls}"` : ''}>${rich(str)}</text>`,
    );
  }
  /** A titled box with muted detail lines. Returns the box geometry for wiring arrows. */
  node(x, y, w, h, { title, lines = [], accent, fill, dash, tsize = 17, lsize = 14.5, center = false } = {}) {
    this.rect(x, y, w, h, { fill, stroke: accent ?? C.nodeStroke, dash, sw: accent ? 1.8 : 1.5 });
    const total = 22 + lines.length * 23;
    let ty = center ? y + (h - total) / 2 + 18 : y + 30;
    if (title) this.text(center ? x + w / 2 : x + 18, ty, title, { size: tsize, weight: 650, fill: accent ?? C.text, anchor: center ? 'middle' : 'start' });
    ty += 26;
    for (const l of lines) {
      this.text(center ? x + w / 2 : x + 18, ty, l, { size: lsize, fill: C.muted, anchor: center ? 'middle' : 'start' });
      ty += 23;
    }
  }
  /** Rounded orthogonal polyline with an arrowhead (and optionally one at the start). */
  arrow(pts, { color = C.arrow, dash, sw = 2.2, both = false, head = true, r = 16 } = {}) {
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
  /** A small label that sits on top of a line (the line is masked behind it). */
  pill(cx, cy, str, { color = C.muted, size = 13, fill = C.bg, stroke } = {}) {
    const plain = str.replace(/`/g, '');
    const w = Math.round(plain.length * size * 0.56 + 22);
    const h = size + 14;
    this.rect(cx - w / 2, cy - h / 2, w, h, { fill, stroke: stroke ?? 'none', sw: 1, r: h / 2 });
    this.text(cx, cy + size * 0.35, str, { size, fill: color, anchor: 'middle' });
  }
  /** A small rounded chip. */
  chip(x, y, w, h, str, { accent, size = 14, fill = C.node } = {}) {
    this.rect(x, y, w, h, { fill, stroke: accent ?? C.nodeStroke, r: h / 2, sw: 1.4 });
    this.text(x + w / 2, y + h / 2 + size * 0.35, str, { size, anchor: 'middle', fill: C.text });
  }
  toString() {
    const defs = [...this.markers]
      .map(
        ([color, id]) =>
          `<marker id="${id}" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="${color}"/></marker>`,
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
  s.rect(x, y, w, h, { fill: 'none', stroke: accent, sw: 1.6, r: 18, dash: '2 0' });
  s.text(x + 22, y + 30, label, { size: 13, weight: 700, fill: accent, ls: '1.6' });
}

// ───────────────────────────── diagrams ─────────────────────────────
const diagrams = {};

// 1 ── README: the big picture ───────────────────────────────────────
diagrams['how-it-works'] = () => {
  const s = new Svg(1400, 530);
  const top = 150, h = 190, mid = top + h / 2;
  const phone = { x: 50, w: 360 }, relay = { x: 550, w: 300 }, mac = { x: 990, w: 360 };

  s.node(phone.x, top, phone.w, h, {
    accent: C.phone,
    title: 'Android phone',
    lines: ['Background app', 'clipboard · lock · battery', 'notifications · SMS · files'],
  });
  s.node(relay.x, top, relay.w, h, {
    accent: C.relay,
    title: 'Your relay (optional)',
    lines: ['Tiny WebSocket server', 'routes by room id', 'sees only ciphertext'],
  });
  s.node(mac.x, top, mac.w, h, {
    accent: C.mac,
    title: 'Mac',
    lines: ['Menu-bar app + dashboard', 'clipboard · lock · pairing QR', 'notifications · messages'],
  });

  // away-from-home path through the relay
  s.arrow([[phone.x + phone.w, mid], [relay.x, mid]], { both: true, color: C.relay });
  s.arrow([[relay.x + relay.w, mid], [mac.x, mid]], { both: true, color: C.relay });
  s.pill((phone.x + phone.w + relay.x) / 2, mid - 28, 'away', { color: C.relay });
  s.pill((relay.x + relay.w + mac.x) / 2, mid - 28, 'away', { color: C.relay });

  // same Wi-Fi: straight over the top
  const lanY = 62;
  s.arrow([[phone.x + 180, top], [phone.x + 180, lanY], [mac.x + 180, lanY], [mac.x + 180, top]], { both: true, color: C.phone, dash: '9 7' });
  s.pill(700, lanY, 'Same Wi-Fi: direct LAN link, no relay in the loop', { color: C.phone, size: 14 });

  // Bluetooth: straight under the bottom
  const bleY = 420;
  s.arrow([[phone.x + 180, top + h], [phone.x + 180, bleY], [mac.x + 180, bleY], [mac.x + 180, top + h]], { both: true, color: C.ble, dash: '3 7' });
  s.pill(700, bleY, 'Bluetooth presence beacon: proximity auto-lock, fully local', { color: C.ble, size: 14 });

  s.text(700, 482, 'Clipboard, files, messages and the lock command are end-to-end encrypted on every path.', { size: 13.5, fill: C.muted, anchor: 'middle' });
  return s;
};

// 2 ── TECHNICAL §1: component architecture ──────────────────────────
diagrams['architecture'] = () => {
  const s = new Svg(1700, 900);
  const P = { x: 40, y: 85, w: 680, h: 665 };
  const M = { x: 1080, y: 85, w: 580, h: 665 };
  frame(s, P.x, P.y, P.w, P.h, 'ANDROID (PHONE)', C.phone);
  frame(s, M.x, M.y, M.w, M.h, 'MACOS', C.mac);

  // phone column
  const bx = 70, bw = 620;
  s.node(bx, 135, bw, 115, { title: 'Expo / React Native app (JS)', lines: ['UI, pairing, settings, Files screen', 'drives the native side through the Expo module'] });
  s.node(bx, 300, bw, 180, {
    accent: C.phone,
    title: 'Foreground Service (Kotlin)',
    lines: ['OkHttp WebSocket → relay / LAN-direct', '`ClipBridge` (localhost client)', '`BleAdvertiser` (presence beacon)'],
  });
  s.node(bx, 550, bw, 160, {
    title: 'ClipboardAgent (shell UID)',
    lines: ['`app_process` daemon', '`IClipboard` reflection', '`ServerSocket` NDJSON'],
  });
  s.arrow([[bx + 310, 250], [bx + 310, 300]], {});
  s.pill(bx + 310 + 105, 275, 'Expo module', {});
  s.arrow([[bx + 310, 480], [bx + 310, 550]], { both: true });
  s.pill(bx + 310 + 130, 515, 'connect 127.0.0.1:53123', {});

  // relay in the middle
  s.node(790, 325, 220, 130, { accent: C.relay, title: 'Relay', lines: ['Node `ws`', 'room routing'], center: true });
  s.text(900, 490, 'Forwards opaque frames by room id.', { size: 13.5, fill: C.muted, anchor: 'middle' });
  s.text(900, 511, 'No storage, no decryption.', { size: 13.5, fill: C.muted, anchor: 'middle' });
  s.arrow([[bx + bw, 390], [790, 390]], { both: true, color: C.relay });
  s.arrow([[1010, 390], [1110, 390]], { both: true, color: C.relay });

  // mac column
  const mx = 1110, mw = 520;
  s.node(mx, 135, mw, 115, { title: 'Clipboard', lines: ['`NSPasteboard` poll (text + images)'] });
  s.node(mx, 300, mw, 180, {
    accent: C.mac,
    title: 'Network',
    lines: ['`URLSession` WebSocket client → relay', 'LAN WebSocket server (`NWListener`) + Bonjour'],
  });
  s.node(mx, 550, mw, 160, {
    title: 'Proximity & system',
    lines: ['`CoreBluetooth` central', '`SACLockScreen` · pairing QR', 'Keychain · Sparkle'],
  });

  // LAN-direct over the top, BLE under the bottom
  s.arrow([[bx + 120, P.y], [bx + 120, 42], [mx + 120, 42], [mx + 120, M.y]], { both: true, color: C.phone, dash: '9 7' });
  s.pill(870, 42, 'Same Wi-Fi: LAN-direct, no relay', { color: C.phone, size: 14 });
  const bleY = 830;
  s.arrow([[bx + 310, P.y + P.h], [bx + 310, bleY], [mx + 310, bleY], [mx + 310, M.y + M.h]], { both: true, color: C.ble, dash: '3 7' });
  s.pill(870, bleY, 'BLE presence beacon: proximity auto-lock, fully local, no relay', { color: C.ble, size: 14 });
  return s;
};

// 3 ── TECHNICAL §3: the Self-ADB layers ─────────────────────────────
diagrams['self-adb-layers'] = () => {
  const s = new Svg(1250, 800);
  const L = { x: 60, w: 500 }, R = { x: 700, w: 490 };
  const y1 = 40, y2 = 215, y3 = 390, y4 = 590;

  s.node(L.x, y1, L.w, 95, { title: 'Expo module', lines: ['control plane, only alive while the JS app runs'] });
  s.node(L.x, y2, L.w, 95, { title: '`libadb-android`', lines: ['pure-Java ADB client (adb-over-TLS)'] });
  s.node(R.x, y2, R.w, 95, { accent: C.phone, title: 'On-device `adbd`', lines: ['Wireless Debugging'] });
  s.node(L.x, y3, L.w, 95, { title: '`app_process`', lines: ['shell-side launcher'] });
  s.node(R.x, y3, R.w, 110, { accent: C.phone, title: 'ClipboardAgent', lines: ['shell UID, detached daemon', 'survives the app'] });
  s.node(L.x, y4, L.w, 150, {
    accent: C.phone,
    title: 'ClipForegroundService',
    lines: ['owns `ClipBridge` (localhost client),', '`RelayClient` (WebSocket) and `BleAdvertiser`', 'survives an app swipe (`START_STICKY`)'],
  });

  s.arrow([[L.x + 250, y1 + 95], [L.x + 250, y2]], {});
  s.pill(L.x + 250 + 120, (y1 + 95 + y2) / 2, 'start / pair / deploy / kill', {});
  s.arrow([[L.x + L.w, y2 + 47], [R.x, y2 + 47]], { color: C.phone });
  s.pill((L.x + L.w + R.x) / 2, y2 + 47, 'TLS + spake2', { color: C.phone });
  s.arrow([[L.x + 250, y2 + 95], [L.x + 250, y3]], {});
  s.pill(L.x + 250 + 100, (y2 + 95 + y3) / 2, 'exec / push streams', {});
  s.arrow([[L.x + L.w, y3 + 47], [R.x, y3 + 47]], { color: C.phone });
  s.pill((L.x + L.w + R.x) / 2, y3 + 47, 'launches', { color: C.phone });
  s.arrow([[R.x + 245, y3 + 110], [R.x + 245, y4 + 75], [L.x + L.w, y4 + 75]], { both: true, color: C.phone });
  s.pill(750, y4 + 75, 'ServerSocket 127.0.0.1:53123 (NDJSON)', { color: C.phone });

  // plane labels on the right
  s.text(R.x, y1 + 40, 'CONTROL PLANE', { size: 12.5, weight: 700, fill: C.muted, ls: '1.6' });
  s.text(R.x, y1 + 62, 'Pairs, deploys and kills the daemon over ADB.', { size: 13.5, fill: C.muted });
  s.text(R.x, y4 + 120, 'DATA PLANE', { size: 12.5, weight: 700, fill: C.muted, ls: '1.6' });
  s.text(R.x, y4 + 142, 'Runs with no ADB and no JS once the daemon is up.', { size: 13.5, fill: C.muted });
  return s;
};

// 4 ── TECHNICAL §3.6: autoStart decision flow ───────────────────────
diagrams['autostart-flow'] = () => {
  const s = new Svg(1340, 1090);
  const X = 60, W = 560, OX = 900, OW = 380, H = 72;
  const cx = X + W / 2;
  const row = { poll: 40, alive: 165, paired: 330, wd: 465, mdns: 590, connect: 715, deploy: 840, ready: 975 };

  const step = (y, title, lines, o = {}) => s.node(X, y, W, H, { title, lines, ...o, center: true });
  const decision = (y, title) => s.node(X, y, W, H, { title, accent: C.ble, center: true });
  const out = (y, title, sub, accent) => s.node(OX, y, OW, H, { title, lines: sub ? [sub] : [], accent, center: true });
  const down = (y1, y2, label, lx) => {
    s.arrow([[cx, y1], [cx, y2]], {});
    if (label) s.pill(lx ?? cx, (y1 + y2) / 2, label, {});
  };
  const right = (y, label, color) => {
    s.arrow([[X + W, y + H / 2], [OX, y + H / 2]], { color });
    s.pill((X + W + OX) / 2, y + H / 2, label, { color });
  };

  step(row.poll, 'Poll `daemonAlive`', ['up to 2.4 s grace window (issue #29)']);
  decision(row.alive, 'Alive, secret known, bridge not flapping?');
  out(row.alive, '“ready”', 'no ADB needed', C.phone);
  decision(row.paired, '`isPaired()`?');
  out(row.paired, '“need-pair”', 'send the user to pairing', C.relay);
  step(row.wd, 'Self-enable Wireless Debugging', ['only if `WRITE_SECURE_SETTINGS` is held']);
  step(row.mdns, 'mDNS discover `_adb-tls-connect`');
  out(row.mdns, '“need-connect”', null, C.relay);
  step(row.connect, 'Drop the stale adb session, then connect', ['`isConnected` → `disconnect`, then connect']);
  out(row.connect, '“need-pair”', 're-pair gate', C.relay);
  step(row.deploy, 'Deploy and start', ['push the dex if needed, launch the daemon, start the service']);
  s.node(cx - 150, row.ready, 300, H, { title: '“ready”', accent: C.phone, center: true });

  down(row.poll + H, row.alive);
  right(row.alive, 'yes', C.phone);
  down(row.alive + H, row.paired, 'no: still dead after the grace window (or secret unknown / bridge flapping)');
  right(row.paired, 'no', C.relay);
  down(row.paired + H, row.wd, 'yes');
  down(row.wd + H, row.mdns);
  right(row.mdns, 'not found', C.relay);
  down(row.mdns + H, row.connect, 'found');
  right(row.connect, 'AdbPairingRequiredException', C.relay);
  down(row.connect + H, row.deploy, 'ok');
  down(row.deploy + H, row.ready);
  return s;
};

// 5 ── TECHNICAL §3.9: Android self-update ───────────────────────────
diagrams['app-update-flow'] = () => {
  const s = new Svg(1250, 0); // height is set once the steps are laid out
  const BX = 150, BW = 1040, BC = 100; // box x/width, badge column x
  const defs = [
    { h: 110, n: '', title: 'Trigger', accent: C.mac },
    { h: 80, n: '1', title: 'Check' },
    { h: 80, n: '2', title: 'Download' },
    { h: 135, n: '3', title: 'Verify' },
    { h: 80, n: '4', title: 'Ready', accent: C.phone },
    { h: 120, n: '5', title: 'Install' },
    { h: 70, n: '6', title: 'The OS replaces the app', accent: C.relay },
  ];
  let yy = 40;
  const steps = defs.map((d) => {
    const st = { ...d, y: yy };
    yy += d.h + 45;
    return st;
  });
  const badge = (st) => {
    const cy = st.y + 26; // level with the box title
    s.add(`<circle cx="${BC}" cy="${cy}" r="22" fill="${C.node}" stroke="${st.accent ?? C.nodeStroke}" stroke-width="1.8"/>`);
    if (st.n) s.text(BC, cy + 6, st.n, { size: 17, weight: 700, anchor: 'middle', fill: st.accent ?? C.text });
    else s.add(`<path d="M${BC - 5} ${cy - 9} L${BC + 10} ${cy} L${BC - 5} ${cy + 9} Z" fill="${st.accent}"/>`); // "start" glyph
    return cy;
  };
  const cys = steps.slice(0, 7).map(badge);
  for (let i = 0; i < 6; i++) s.arrow([[BC, cys[i] + 22], [BC, cys[i + 1] - 22]], {});

  const tx = BX + 20;
  const box = (i, lines, extra = {}) => {
    const st = steps[i];
    s.rect(BX, st.y, BW, st.h, { stroke: st.accent ?? C.nodeStroke, sw: st.accent ? 1.8 : 1.5 });
    s.text(tx, st.y + 31, st.title, { size: 17, weight: 650, fill: st.accent ?? C.text });
    lines.forEach((l, k) => s.text(tx, st.y + 58 + k * 23, l, { size: 14.5, fill: C.muted }));
    return st;
  };

  box(0, ['`ClipForegroundService` calls `schedule()` (or the JS `checkAppUpdate`, or an app launch) → `AppUpdater`', 'First check about 60 s after start, then every 6 h. One retry after 15 min if the probe failed.']);
  box(1, ['`GET releases/latest`: is it newer than the installed `versionName`?']);
  box(2, ['To `cacheDir/updates/<v>.apk.part` (OkHttp, Range-resumed, progress → `onAppUpdate`)']);
  {
    const st = box(3, ['Rename the finished file, then check all of:']);
    const chips = ['SHA-256 (asset `digest`)', 'same package', 'higher `versionCode`', 'signing certificate shared with the installed app'];
    const widths = [215, 140, 175, 400];
    let x = tx;
    chips.forEach((c, i) => {
      s.chip(x, st.y + 80, widths[i], 38, c, {});
      x += widths[i] + 14;
    });
  }
  box(4, ['`UpdateNotifier`: “Update ready, tap to install” (or the sheet’s Install button)']);
  {
    const st = box(5, []);
    const items = [
      ['`InstallActivity`', 200, undefined],
      ['Install unknown apps (first time only)', 300, C.relay],
      ['`PackageInstaller` session', 235, undefined],
      ['system “Update” screen', 190, undefined],
    ];
    let x = tx;
    const y = st.y + 58;
    items.forEach(([t, w, accent], i) => {
      s.chip(x, y, w, 38, t, { accent });
      if (i < items.length - 1) s.arrow([[x + w + 4, y + 19], [x + w + 22, y + 19]], { sw: 2 });
      x += w + 26;
    });
  }
  {
    const st = steps[6];
    s.rect(BX, st.y, BW, st.h, { stroke: st.accent, sw: 1.8 });
    s.text(tx, st.y + 31, st.title, { size: 17, weight: 650, fill: st.accent });
    s.text(tx, st.y + 56, '`PackageReplacedReceiver`: `reset()` the record and files, then restart `ClipForegroundService`.', { size: 14.5, fill: C.muted });
  }
  s.h = yy - 45 + 40;
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
