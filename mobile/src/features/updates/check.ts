import Constants from 'expo-constants';
import * as Updates from 'expo-updates';

import SelfAdb, { type AppUpdateState, type AppUpdateStatus } from '@/features/selfadb/client';

/**
 * Two different kinds of "newer version" can exist for the Android app, and each needs a different
 * action:
 *
 *  - **OTA** — a JS-only EAS Update published against the *current* runtimeVersion. `expo-updates`
 *    fetches it and reloads in place. Only meaningful in release builds (`Updates.isEnabled`).
 *  - **native** — a whole new APK. The `appVersion` runtime policy ties runtimeVersion to the app
 *    version (see app.config.ts), so any version bump rebuilds natively and `expo-updates` will
 *    NOT see it — there's no matching update for the new runtime. These are found on the GitHub
 *    "latest" release (the mobile counterpart of the Mac's Sparkle appcast: both are served from the
 *    same release). The `selfadb` module's `AppUpdater` does the finding AND fetches the APK in the
 *    background, so the user's part is one tap on the system installer; see `use-app-update.tsx`
 *    for the JS side and TECHNICAL.md for the native one.
 */

const REPO = 'grkndev/LinkToMac';
const LATEST_RELEASE_API = `https://api.github.com/repos/${REPO}/releases/latest`;

/** A newer APK, as the sheet needs it. `state` is the native downloader's. */
export type NativeUpdate = {
  kind: 'native';
  version: string;
  notes: string | null;
  /** The APK, else the release page — what the browser fallback opens. */
  url: string;
  state: AppUpdateStatus;
  /** 0..100 while `downloading`. */
  progress: number;
  /** The app can fetch the APK itself (a release asset exists). False → the browser fallback. */
  downloadable: boolean;
  /** Why the last background download failed (`failed` only). */
  error: string | null;
};

export type AppUpdate =
  | { kind: 'none' }
  /** The check itself failed (connectivity / API error) — "no update found" would be a lie. */
  | { kind: 'failed' }
  | { kind: 'ota' }
  | NativeUpdate;

/** The app's installed native version (e.g. "0.2.0"). */
export function currentVersion(): string {
  return Constants.expoConfig?.version ?? '0.0.0';
}

/**
 * Compare dotted numeric versions. Returns >0 when `a` is newer than `b`, 0 when equal, <0 when
 * older. Tolerates a leading "v" and differing segment counts ("0.2" vs "0.2.0").
 */
export function compareVersions(a: string, b: string): number {
  const parse = (v: string) =>
    v.replace(/^v/, '').split('.').map((n) => parseInt(n, 10) || 0);
  const pa = parse(a);
  const pb = parse(b);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d;
  }
  return 0;
}

/** Map the native updater's state onto what the sheet shows. Null when nothing newer is pending. */
export function toNativeUpdate(s: AppUpdateState): NativeUpdate | null {
  if (!s.version || !s.url) return null;
  return {
    kind: 'native',
    version: s.version,
    notes: s.notes,
    url: s.url,
    state: s.state,
    progress: s.progress,
    downloadable: s.downloadable,
    error: s.error,
  };
}

type GithubAsset = { name: string; browser_download_url: string };
type GithubRelease = {
  tag_name: string;
  html_url: string;
  body?: string;
  assets?: GithubAsset[];
};

/**
 * The pre-updater path: ask GitHub directly and offer the APK as a browser download. Only used when
 * the native module can't do it itself (a binary built before `checkAppUpdate` existed).
 */
async function fetchLatestFromGithub(signal?: AbortSignal): Promise<NativeUpdate | null | 'failed'> {
  try {
    const res = await fetch(LATEST_RELEASE_API, {
      headers: { Accept: 'application/vnd.github+json' },
      signal,
    });
    if (!res.ok) return 'failed';
    const data = (await res.json()) as GithubRelease;
    const version = (data.tag_name ?? '').replace(/^v/, '');
    if (!version) return 'failed';
    if (compareVersions(version, currentVersion()) <= 0) return null;
    const apk = data.assets?.find((a) => /\.apk$/i.test(a.name));
    return {
      kind: 'native',
      version,
      notes: data.body?.trim() ? data.body.trim() : null,
      url: apk?.browser_download_url ?? data.html_url,
      state: 'idle',
      progress: 0,
      downloadable: false,
      error: null,
    };
  } catch {
    return 'failed';
  }
}

/** Newer native release: the update, `null` for "current", `'failed'` when the probe didn't work. */
async function probeNative(signal?: AbortSignal): Promise<NativeUpdate | null | 'failed'> {
  // An OTA bundle can land on a binary that predates the updater; fall back rather than throw.
  if (typeof SelfAdb.checkAppUpdate !== 'function') return fetchLatestFromGithub(signal);
  try {
    const s = await SelfAdb.checkAppUpdate();
    if (!s.checked) return 'failed';
    return toNativeUpdate(s);
  } catch {
    return 'failed';
  }
}

/**
 * Resolve which update (if any) to offer. Native takes precedence: a newer APK is the bigger
 * change and an OTA only ever ships under the same version, so a newer GitHub version always means
 * the JS-only path can't deliver it. Falls back to an OTA check for the current runtime otherwise.
 *
 * Returns `{kind:'failed'}` when no update was found AND the native probe failed — "up to date"
 * is only ever claimed after the native check actually succeeded (a manual check on a dead
 * connection must say "check failed", not lie).
 */
export async function checkForAppUpdate(signal?: AbortSignal): Promise<AppUpdate> {
  const native = await probeNative(signal);
  if (native && native !== 'failed') return native;
  if (Updates.isEnabled) {
    try {
      const result = await Updates.checkForUpdateAsync();
      if (result.isAvailable) return { kind: 'ota' };
    } catch {
      // Network/registry hiccup — the native-check result below decides none vs failed.
    }
  }
  return native === 'failed' ? { kind: 'failed' } : { kind: 'none' };
}
