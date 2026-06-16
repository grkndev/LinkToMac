// Relay connection config. The room is no longer here — it comes from QR pairing
// (scanned from the Mac, persisted via expo-secure-store; see pairing-store.ts).
// Host + token come from the environment via app.config.ts -> expoConfig.extra, so the
// secret lives in a gitignored .env (see .env.example), not in tracked source. RELAY_TOKEN
// stays app-global (defense-in-depth on top of the room bearer).

import Constants from 'expo-constants';

/** Used only if the Metro dev-server host can't be derived (set to your Mac's LAN IP). */
const FALLBACK_HOST = 'YOUR_RELAY_HOST';

/**
 * Host where the relay is reachable FROM THE PHONE.
 *
 * Priority:
 *   1. `expoConfig.extra.relayHost`, injected from the RELAY_HOST env var by app.config.ts.
 *      Use this to pin the relay to a deployed/remote server. NOTE: do NOT put this in
 *      `expo.hostUri` — that is a reserved
 *      Expo field used to build the dev deep-link base, and a bare IP there makes Expo Router
 *      open `linktomac://<ip>/` on launch ("Unmatched route").
 *   2. The Metro dev-server host. When the relay runs on the same Mac as Metro this auto-tracks
 *      the Mac's LAN IP. `hostUri` looks like "127.0.0.1:8081"; on a device localhost/loopback
 *      points back at the phone, so we ignore those.
 *   3. FALLBACK_HOST.
 */
function resolveHost(): string {
  const override = Constants.expoConfig?.extra?.relayHost as string | undefined;
  if (override) return override;

  const host = Constants.expoConfig?.hostUri?.split(':')[0];
  if (host && host !== 'localhost' && host !== '127.0.0.1') return host;
  return FALLBACK_HOST;
}

export const RELAY_HOST = resolveHost();
export const RELAY_PORT = 59183;
export const RELAY_PATH = '/ws';

/** Same token as server/.env (RELAY_AUTH_TOKEN), sent as a Bearer header. Injected from the
 *  RELAY_TOKEN env var via app.config.ts -> expoConfig.extra; empty if .env isn't set up. */
export const RELAY_TOKEN =
  (Constants.expoConfig?.extra?.relayToken as string | undefined) ?? '';

export function relayUrl(): string {
  return `ws://${RELAY_HOST}:${RELAY_PORT}${RELAY_PATH}`;
}
