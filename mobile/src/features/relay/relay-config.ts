// Relay connection config. The room is no longer here — it comes from QR pairing
// (scanned from the Mac, persisted via expo-secure-store; see pairing-store.ts).
// RELAY_TOKEN stays app-global (defense-in-depth on top of the room bearer).

import Constants from 'expo-constants';

/** Used only if the Metro dev-server host can't be derived (set to your Mac's LAN IP). */
const FALLBACK_HOST = '51.38.98.148';

/**
 * Host where the relay is reachable FROM THE PHONE.
 *
 * Priority:
 *   1. An explicit override in app.json -> expo.extra.relayHost. Use this to pin the relay to
 *      a deployed/remote server. NOTE: do NOT put this in `expo.hostUri` — that is a reserved
 *      Expo field used to build the dev deep-link base, and a bare IP there makes Expo Router
 *      open `mobile://<ip>/` on launch ("Unmatched route").
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

/** Same token as server/.env (RELAY_AUTH_TOKEN), sent as a Bearer header. */
export const RELAY_TOKEN = 'c94bff35f554588c211b520b935c583ef8f33bb25eab1932e52575e9926c1804';

export function relayUrl(): string {
  return `ws://${RELAY_HOST}:${RELAY_PORT}${RELAY_PATH}`;
}
