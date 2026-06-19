import Constants from 'expo-constants';
import * as Updates from 'expo-updates';

/**
 * Two different kinds of "newer version" can exist for the Android app, and each needs a different
 * action:
 *
 *  - **OTA** — a JS-only EAS Update published against the *current* runtimeVersion. `expo-updates`
 *    fetches it and reloads in place. Only meaningful in release builds (`Updates.isEnabled`).
 *  - **native** — a whole new APK. The `appVersion` runtime policy ties runtimeVersion to the app
 *    version (see app.config.ts), so any version bump rebuilds natively and `expo-updates` will
 *    NOT see it — there's no matching update for the new runtime. We discover these from the
 *    GitHub "latest" release and send the user off to download the APK. This is the mobile
 *    counterpart of the Mac's Sparkle appcast: both are served from the same GitHub release.
 */

const REPO = 'grkndev/LinkToMac';
const LATEST_RELEASE_API = `https://api.github.com/repos/${REPO}/releases/latest`;

export type AppUpdate =
  | { kind: 'none' }
  | { kind: 'ota' }
  | { kind: 'native'; version: string; notes: string | null; url: string };

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

type GithubAsset = { name: string; browser_download_url: string };
type GithubRelease = {
  tag_name: string;
  html_url: string;
  body?: string;
  assets?: GithubAsset[];
};

/** The latest published native release on GitHub, or null on any network/parse failure. */
export async function fetchLatestNativeRelease(
  signal?: AbortSignal,
): Promise<{ version: string; notes: string | null; url: string } | null> {
  try {
    const res = await fetch(LATEST_RELEASE_API, {
      headers: { Accept: 'application/vnd.github+json' },
      signal,
    });
    if (!res.ok) return null;
    const data = (await res.json()) as GithubRelease;
    const version = (data.tag_name ?? '').replace(/^v/, '');
    if (!version) return null;
    // Prefer the direct APK asset (one tap → download → install); fall back to the release page.
    const apk = data.assets?.find((a) => /\.apk$/i.test(a.name));
    return {
      version,
      notes: data.body?.trim() ? data.body.trim() : null,
      url: apk?.browser_download_url ?? data.html_url,
    };
  } catch {
    return null;
  }
}

/**
 * Resolve which update (if any) to offer. Native takes precedence: a newer APK is the bigger
 * change and an OTA only ever ships under the same version, so a newer GitHub version always means
 * the JS-only path can't deliver it. Falls back to an OTA check for the current runtime otherwise.
 */
export async function checkForAppUpdate(signal?: AbortSignal): Promise<AppUpdate> {
  const latest = await fetchLatestNativeRelease(signal);
  if (latest && compareVersions(latest.version, currentVersion()) > 0) {
    return { kind: 'native', version: latest.version, notes: latest.notes, url: latest.url };
  }
  if (Updates.isEnabled) {
    try {
      const result = await Updates.checkForUpdateAsync();
      if (result.isAvailable) return { kind: 'ota' };
    } catch {
      // Network/registry hiccup — treat as "no OTA" and stay quiet.
    }
  }
  return { kind: 'none' };
}
