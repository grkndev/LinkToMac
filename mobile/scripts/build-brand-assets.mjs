#!/usr/bin/env node
// Generates every brand image and the "Synced Mac" in-app icon from ONE glyph definition, so the
// launcher icon, splash, notification icon and the Home icon can never drift apart.
//
//   cd mobile && node scripts/build-brand-assets.mjs
//
// Needs a Chromium-based browser (Chrome / Brave / Chromium / Edge) to rasterise; it is only a
// build-time tool, nothing here ships in the app.
//
// Source of truth: the Android redesign (mark "2a — Synced Mac"): a laptop with two-way sync
// arrows cut into its screen, on #2E4C9E. 108dp adaptive-icon canvas, 66dp safe zone.
//
// Writes:
//   assets/images/icon.png                    1024 opaque, full-bleed (legacy / store icon)
//   assets/images/android-icon-foreground.png 1024, white mark on transparent, 108dp canvas
//   assets/images/android-icon-monochrome.png 1024, Rounded-Stroke mark on transparent (themed icon)
//   assets/splash/splash-anim.xml             native splash: AnimatedVectorDrawable, 1 s intro, light
//   assets/splash/splash-anim-night.xml       same, dark colours (expo-splash-screen copies both into res/)
//   assets/boot/{laptop,base,arrow-top,arrow-bottom,wordmark}.png   the glyph's layers + the app name for the Boot overlay (white, tinted at runtime)
//   src/features/boot/splash-storyboard.generated.ts   the storyboard + layout numbers the in-app replay/Boot share with the AVD
//   modules/selfadb/.../drawable-*/ic_stat_link.png   24dp status-bar icon, 5 densities
//   assets/icons/laptop_mac.xml               in-app icon, Rounded Stroke  (idle)
//   assets/icons/laptop_mac_twotone.xml       in-app icon, Rounded Twotone (connected / active)
//
// The adaptive-icon background is a flat colour (BRAND, set in app.config.ts), not an image.
// Splash + Boot use their own geometry (SPLASH_GEO below, straight from the design's "Splash" artboards):
// no shape behind the mark, the arrows are drawn in the BACKGROUND colour so they read as cut-outs, and the
// four parts animate independently. The Boot overlay (src/components/booting.tsx) must be pixel-identical to
// the AVD's last frame, which is why both are generated from the same numbers.
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import opentype from 'opentype.js'; // devDependency: turns the app name into vector outlines for the AVD

const MOBILE = join(dirname(fileURLToPath(import.meta.url)), '..');
const BRAND = '#2E4C9E';

// ─────────────────────────── the glyph, on a 108-unit canvas ───────────────────────────
const MARK = (sw) => `
  <mask id="m"><rect width="108" height="108" fill="#000"/>
    <rect x="32" y="36" width="44" height="30" rx="6" fill="#fff"/>
    <rect x="28" y="68" width="52" height="5" rx="2.5" fill="#fff"/>
    <path d="M44 46H64M60.5 42.5L64 46L60.5 49.5M64 56H44M47.5 52.5L44 56L47.5 59.5" stroke="#000" stroke-width="${sw}" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
  </mask>`;

/** The filled mark (arrows cut out) on a 108 canvas. */
const markSvg = ({ px, view, sw = 3, ink = '#fff', bg, disc }) => `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" viewBox="${view}">
  <defs>${MARK(sw)}${disc ? '<clipPath id="c"><circle cx="54" cy="54" r="36"/></clipPath>' : ''}</defs>
  <g${disc ? ' clip-path="url(#c)"' : ''}>
    ${bg ? `<rect x="0" y="0" width="108" height="108" fill="${bg}"/>` : ''}
    <rect width="108" height="108" fill="${ink}" mask="url(#m)"/>
  </g>
</svg>`;

/** The Rounded-Stroke line glyph on a 24 grid, scaled into the 66dp safe zone of a 108 canvas. */
const strokeSvg = ({ px, sw = 1.75, ink = '#000' }) => `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" viewBox="0 0 108 108">
  <g transform="translate(54 54) scale(2.75) translate(-12 -12)" fill="none" stroke="${ink}" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round">
    <rect x="3.5" y="3.5" width="17" height="12.5" rx="3"/>
    <path d="M2 19.5H22"/>
    <path d="M8 7.5H16M14.25 5.75L16 7.5L14.25 9.25M16 12H8M9.75 10.25L8 12L9.75 13.75"/>
  </g>
</svg>`;

// ─────────────────────────── rasterising ───────────────────────────
const BROWSERS = [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
];
const browser = BROWSERS.find((p) => spawnSync('test', ['-x', p]).status === 0);
if (!browser) {
  console.error('No Chromium-based browser found in /Applications.');
  process.exit(1);
}
const work = mkdtempSync(join(tmpdir(), 'brand-'));
let n = 0;

function shot(src, w, h, outPath) {
  mkdirSync(dirname(outPath), { recursive: true });
  const r = spawnSync(
    browser,
    [
      '--headless=new', '--disable-gpu', '--hide-scrollbars',
      '--allow-file-access-from-files', '--virtual-time-budget=3000', // lets @font-face files load
      '--default-background-color=00000000',
      '--force-device-scale-factor=1',
      `--window-size=${w},${h}`,
      `--screenshot=${outPath}`,
      `file://${src}`,
    ],
    { encoding: 'utf8' },
  );
  if (r.status !== 0) {
    console.error(r.stderr);
    process.exit(1);
  }
  console.log(`  ${outPath.replace(MOBILE + '/', '')}  ${w}x${h}`);
}

function png(svg, px, outPath) {
  const src = join(work, `a${n++}.svg`);
  writeFileSync(src, svg);
  shot(src, px, px, outPath);
}

// ─────────────────────────── PNG assets ───────────────────────────
const img = (f) => join(MOBILE, 'assets/images', f);

// Legacy / store icon: full-bleed, the 72-unit window the design uses for its tile.
png(markSvg({ px: 1024, view: '18 18 72 72', sw: 3, bg: BRAND }), 1024, img('icon.png'));
// Adaptive foreground: the whole 108 canvas, so the launcher mask crops the *background* only.
png(markSvg({ px: 1024, view: '0 0 108 108', sw: 3 }), 1024, img('android-icon-foreground.png'));
// Themed (monochrome) icon: Android uses only the alpha channel and tints it.
png(strokeSvg({ px: 1024 }), 1024, img('android-icon-monochrome.png'));

// Status-bar icon: 24dp with 2dp padding (a 64.8-unit window of the canvas), arrows a touch heavier.
const RES = join(MOBILE, 'modules/selfadb/android/src/main/res');
for (const [density, px] of [['mdpi', 24], ['hdpi', 36], ['xhdpi', 48], ['xxhdpi', 72], ['xxxhdpi', 96]]) {
  png(markSvg({ px, view: '21.6 21.6 64.8 64.8', sw: 4 }), px, join(RES, `drawable-${density}`, 'ic_stat_link.png'));
}

const f = (v) => String(Math.round(v * 1000) / 1000);

// ─────────────────────────── splash + boot glyph ───────────────────────────
// 76-unit window (16..92) of the design's 108 canvas, centre (54,54), shown 172dp wide.
const SPLASH_GEO = {
  laptop: 'M38 36H70A6 6 0 0 1 76 42V60A6 6 0 0 1 70 66H38A6 6 0 0 1 32 60V42A6 6 0 0 1 38 36Z',
  base: 'M30.5 68H77.5A2.5 2.5 0 0 1 77.5 73H30.5A2.5 2.5 0 0 1 30.5 68Z',
  arrowTop: 'M44 46H64M60.5 42.5L64 46L60.5 49.5',
  arrowBottom: 'M64 56H44M47.5 52.5L44 56L47.5 59.5',
};
const SPLASH_DP = 172; // glyph window, dp (the design renders its 76-unit viewBox at 172)
const SPLASH_WINDOW = 76;

// The app name under the icon. It is part of the splash's LAST frame, so Boot repeats it exactly: both come from
// this one outline. Units are the glyph window's (centre 54,54; laptop base ends at 73).
const WORDMARK = { text: 'Link to Mac', sizeU: 7.5, baselineU: 86, centreX: 54 }; // 7.5 u ≈ 17 dp
// The mask: a strip right under the base. The text starts ABOVE it (clipped away, i.e. "under the icon") and slides
// down into it; nothing shows outside the strip. y2 is the window's bottom edge.
const STRIP = { x1: 18, y1: 76, x2: 90, y2: 92 };
// Glyph + wordmark are lifted together so the block is centred and the text clears the system's 192 dp circle.
const LIFT_DP = 14;
const WORDMARK_PATH = (() => {
  const ttf = readFileSync(
    join(MOBILE, 'node_modules/@expo-google-fonts/google-sans-flex/600SemiBold/GoogleSansFlex_600SemiBold.ttf'),
  );
  const font = opentype.parse(ttf.buffer.slice(ttf.byteOffset, ttf.byteOffset + ttf.byteLength));
  const adv = font.getAdvanceWidth(WORDMARK.text, WORDMARK.sizeU);
  return font
    .getPath(WORDMARK.text, WORDMARK.centreX - adv / 2, WORDMARK.baselineU, WORDMARK.sizeU)
    .toPathData(2);
})();

// Boot overlay: the four layers as white PNGs (4x), tinted at runtime (laptop/base = glyph colour,
// arrows = background colour). Same 76-unit window, so stacking them in a 172dp box reproduces the AVD's end frame.
{
  const layer = (body) =>
    `<svg xmlns="http://www.w3.org/2000/svg" width="${SPLASH_DP * 4}" height="${SPLASH_DP * 4}" viewBox="16 16 76 76">${body}</svg>`;
  const fill = (d) => layer(`<path d="${d}" fill="#fff"/>`);
  const line = (d) =>
    layer(`<path d="${d}" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>`);
  const boot = (f) => join(MOBILE, 'assets/boot', f);
  png(fill(SPLASH_GEO.laptop), SPLASH_DP * 4, boot('laptop.png'));
  png(fill(SPLASH_GEO.base), SPLASH_DP * 4, boot('base.png'));
  png(line(SPLASH_GEO.arrowTop), SPLASH_DP * 4, boot('arrow-top.png'));
  png(line(SPLASH_GEO.arrowBottom), SPLASH_DP * 4, boot('arrow-bottom.png'));
  png(fill(WORDMARK_PATH), SPLASH_DP * 4, boot('wordmark.png'));
}

// The design's "Splash animation" storyboard as data: [fraction of 1000 ms, value]. ONE source for the native
// AVD below AND the in-app replay (src/features/boot/splash-storyboard.generated.ts, used by the dev preview
// screens), so the two cannot drift. Translations are in glyph units.
const SPLASH_MS = 1000;
const STORYBOARD = {
  laptopScale: [[0, 0.5], [0.15, 0.68], [0.35, 1.06], [0.6, 1]],
  laptopAlpha: [[0, 0], [0.15, 0.45], [0.35, 1]],
  baseScaleX: [[0, 0], [0.15, 0], [0.35, 0.35], [0.6, 1.04], [0.8, 1]],
  arrowTopX: [[0, -12], [0.35, -12], [0.6, -3], [0.8, 1], [1, 0]],
  arrowTopAlpha: [[0, 0], [0.35, 0], [0.6, 0.8], [0.8, 1]],
  arrowBottomX: [[0, 12], [0.35, 12], [0.6, 10], [0.8, -1.5], [1, 0]],
  arrowBottomAlpha: [[0, 0], [0.35, 0], [0.6, 0.15], [0.8, 1]],
  // The name slides down out of the mask once the icon has mostly landed; a hair of overshoot, then rest.
  wordmarkY: [[0, -12], [0.5, -12], [0.78, 1], [0.95, 0], [1, 0]],
};
{
  const out = join(MOBILE, 'src/features/boot/splash-storyboard.generated.ts');
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(
    out,
    `// Generated by scripts/build-brand-assets.mjs — edit the script, not this file.
// The design's splash storyboard: [fraction of SPLASH_MS, value] keyframes. Translations are in glyph units.
export const SPLASH_MS = ${SPLASH_MS};
export const SPLASH_STORYBOARD = ${JSON.stringify(STORYBOARD, null, 2)} as const;
/** Layout shared by the AVD, the Boot overlay and the preview: the lift (dp) and the mask strip (glyph units). */
export const SPLASH_LAYOUT = ${JSON.stringify({ liftDp: LIFT_DP, strip: STRIP }, null, 2)} as const;
`,
  );
}

// Native splash: an AnimatedVectorDrawable (Android 12+ plays it, once; older versions show the end state).
// 288dp canvas = the icon size the system uses when there is no icon background (192dp visible circle);
// the glyph window is centred in it. Keyframes are the design's "Splash animation" storyboard (ms/1000).
// Opacity lives on the PATHS (fillAlpha/strokeAlpha): a vector group has no alpha property.
function splashAvd({ glyph, bg, ink }) {
  const k = SPLASH_DP / SPLASH_WINDOW; // dp per unit
  const vp = 288 / k; // canvas, in units
  const off = vp / 2 - 54; // centre the (54,54) glyph centre
  const liftU = LIFT_DP / k; // the whole glyph + wordmark block sits this much higher
  const T = (name, props) => `  <target android:name="${name}">
    <aapt:attr name="android:animation">
      <objectAnimator android:duration="${SPLASH_MS}">
${props
  .map(
    ([prop, frames]) => `        <propertyValuesHolder android:propertyName="${prop}" android:valueType="floatType">
${(frames.at(-1)[0] < 1 ? [...frames, [1, frames.at(-1)[1]]] : frames) // always end exactly at fraction 1
  .map(
    ([t, v], i) =>
      `          <keyframe android:fraction="${t}" android:value="${v}"${i ? ' android:interpolator="@android:interpolator/fast_out_slow_in"' : ''}/>`,
  )
  .join('\n')}
        </propertyValuesHolder>`,
  )
  .join('\n')}
      </objectAnimator>
    </aapt:attr>
  </target>`;
  const stroke = (name, d) =>
    `<path android:name="${name}" android:strokeColor="${bg}" android:strokeWidth="3" android:strokeLineCap="round" android:strokeLineJoin="round" android:pathData="${d}"/>`;
  return `<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by scripts/build-brand-assets.mjs — edit the script, not this file. -->
<animated-vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt">
  <aapt:attr name="android:drawable">
    <vector
        android:width="288dp"
        android:height="288dp"
        android:viewportWidth="${f(vp)}"
        android:viewportHeight="${f(vp)}">
      <group android:translateX="${f(off)}" android:translateY="${f(off - liftU)}">
        <group android:name="laptop" android:pivotX="54" android:pivotY="54">
          <path android:name="laptop_p" android:fillColor="${glyph}" android:pathData="${SPLASH_GEO.laptop}"/>
        </group>
        <group android:name="base" android:pivotX="54" android:pivotY="70.5">
          <path android:name="base_p" android:fillColor="${glyph}" android:pathData="${SPLASH_GEO.base}"/>
        </group>
        <group android:name="arrow_top">${stroke('arrow_top_p', SPLASH_GEO.arrowTop)}</group>
        <group android:name="arrow_bottom">${stroke('arrow_bottom_p', SPLASH_GEO.arrowBottom)}</group>
        <group android:name="wordmark_mask">
          <clip-path android:pathData="M${STRIP.x1} ${STRIP.y1}H${STRIP.x2}V${STRIP.y2}H${STRIP.x1}Z"/>
          <group android:name="wordmark">
            <path android:name="wordmark_p" android:fillColor="${ink}" android:pathData="${WORDMARK_PATH}"/>
          </group>
        </group>
      </group>
    </vector>
  </aapt:attr>
${T('laptop', [
  ['scaleX', STORYBOARD.laptopScale],
  ['scaleY', STORYBOARD.laptopScale],
])}
${T('laptop_p', [['fillAlpha', STORYBOARD.laptopAlpha]])}
${T('base', [['scaleX', STORYBOARD.baseScaleX]])}
${T('arrow_top', [['translateX', STORYBOARD.arrowTopX]])}
${T('arrow_top_p', [['strokeAlpha', STORYBOARD.arrowTopAlpha]])}
${T('arrow_bottom', [['translateX', STORYBOARD.arrowBottomX]])}
${T('arrow_bottom_p', [['strokeAlpha', STORYBOARD.arrowBottomAlpha]])}
${T('wordmark', [['translateY', STORYBOARD.wordmarkY]])}
</animated-vector>
`;
}
const SPLASH_DIR = join(MOBILE, 'assets/splash');
mkdirSync(SPLASH_DIR, { recursive: true });
writeFileSync(join(SPLASH_DIR, 'splash-anim.xml'), splashAvd({ glyph: '#3F5590', bg: '#F6F7FB', ink: '#1A1C22' }));
writeFileSync(join(SPLASH_DIR, 'splash-anim-night.xml'), splashAvd({ glyph: '#AEBEEA', bg: '#121317', ink: '#E3E4EC' }));
console.log('  assets/splash/splash-anim.xml, splash-anim-night.xml');

// ─────────────────────────── in-app vector icons ───────────────────────────
// @expo/ui's VectorIconLoader reads only filled <path>s: no strokes, groups, fill rules or
// opacity attributes. So the line glyph is expressed as FILLED outlines: nonzero winding, the
// screen's inner edge wound against its outer edge to leave a hole, and every stroke segment a
// round-ended capsule (the union of capsules is exactly a round-cap, round-join stroke).
const R = 0.75; // half of the 1.5 stroke

const roundRect = (x, y, w, h, r, ccw) =>
  ccw
    ? `M${f(x + r)},${f(y)}A${f(r)},${f(r)} 0 0 0 ${f(x)},${f(y + r)}V${f(y + h - r)}A${f(r)},${f(r)} 0 0 0 ${f(x + r)},${f(y + h)}H${f(x + w - r)}A${f(r)},${f(r)} 0 0 0 ${f(x + w)},${f(y + h - r)}V${f(y + r)}A${f(r)},${f(r)} 0 0 0 ${f(x + w - r)},${f(y)}Z`
    : `M${f(x + r)},${f(y)}H${f(x + w - r)}A${f(r)},${f(r)} 0 0 1 ${f(x + w)},${f(y + r)}V${f(y + h - r)}A${f(r)},${f(r)} 0 0 1 ${f(x + w - r)},${f(y + h)}H${f(x + r)}A${f(r)},${f(r)} 0 0 1 ${f(x)},${f(y + h - r)}V${f(y + r)}A${f(r)},${f(r)} 0 0 1 ${f(x + r)},${f(y)}Z`;

/** A stroked segment with round caps, as one filled outline (always wound the same way). */
const capsule = ([x1, y1], [x2, y2], r = R) => {
  const len = Math.hypot(x2 - x1, y2 - y1);
  const nx = (-(y2 - y1) / len) * r, ny = ((x2 - x1) / len) * r;
  return `M${f(x1 + nx)},${f(y1 + ny)}L${f(x2 + nx)},${f(y2 + ny)}A${f(r)},${f(r)} 0 0 0 ${f(x2 - nx)},${f(y2 - ny)}L${f(x1 - nx)},${f(y1 - ny)}A${f(r)},${f(r)} 0 0 0 ${f(x1 + nx)},${f(y1 + ny)}Z`;
};

// Stroke centrelines on the 24 grid (same numbers as the design's icon set).
const SCREEN = { x: 3.5, y: 3.5, w: 17, h: 12.5, r: 3 };
const body =
  roundRect(SCREEN.x - R, SCREEN.y - R, SCREEN.w + 2 * R, SCREEN.h + 2 * R, SCREEN.r + R, false) + // outer
  roundRect(SCREEN.x + R, SCREEN.y + R, SCREEN.w - 2 * R, SCREEN.h - 2 * R, SCREEN.r - R, true) + // inner (hole)
  capsule([2, 19.5], [22, 19.5]); // base
const arrows = [
  [[8, 7.5], [16, 7.5]],
  [[14.25, 5.75], [16, 7.5]],
  [[16, 7.5], [14.25, 9.25]],
  [[16, 12], [8, 12]],
  [[9.75, 10.25], [8, 12]],
  [[8, 12], [9.75, 13.75]],
]
  .map(([a, b]) => capsule(a, b))
  .join('');

const xml = (paths) => `<!-- Generated by scripts/build-brand-assets.mjs — edit the script, not this file. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24"
    android:tint="?attr/colorControlNormal">
${paths.map(([color, d]) => `  <path\n      android:fillColor="${color}"\n      android:pathData="${d}"/>`).join('\n')}
</vector>
`;
const icons = join(MOBILE, 'assets/icons');
// Stroke: everything at full strength. Twotone: the laptop at 40%, the arrows full.
writeFileSync(join(icons, 'laptop_mac.xml'), xml([['#FFFFFFFF', body + arrows]]));
writeFileSync(join(icons, 'laptop_mac_twotone.xml'), xml([['#66FFFFFF', body], ['#FFFFFFFF', arrows]]));
console.log('  assets/icons/laptop_mac.xml, laptop_mac_twotone.xml');
