// Relay connection config. The room is no longer here — it comes from QR pairing
// (scanned from the Mac, persisted via expo-secure-store; see pairing-store.ts).
// RELAY_TOKEN stays app-global (defense-in-depth on top of the room bearer).

import Constants from 'expo-constants';

/** Used only if the Metro dev-server host can't be derived (set to your Mac's LAN IP). */
const FALLBACK_HOST = '10.148.104.103';

/**
 * Host where the relay is reachable FROM THE PHONE. The relay runs on the same Mac as the
 * Metro dev server, and the phone already reaches Metro on that IP — so in development we
 * derive the relay host from the dev-server URI. This auto-tracks the Mac's LAN IP, so a
 * changing IP no longer breaks the connection (the bug that bit us before).
 *
 * `hostUri` looks like "10.148.104.103:8081". On a device, localhost/loopback would point
 * back at the phone, so we ignore those and fall back to the hardcoded LAN IP.
 */
function resolveHost(): string {
  const host = Constants.expoConfig?.hostUri?.split(':')[0];
  if (host && host !== 'localhost' && host !== '127.0.0.1') return host;
  return FALLBACK_HOST;
}

export const RELAY_HOST = resolveHost();
export const RELAY_PORT = 8080;
export const RELAY_PATH = '/ws';

/** Same token as server/.env (RELAY_AUTH_TOKEN), sent as a Bearer header. */
export const RELAY_TOKEN = 'c94bff35f554588c211b520b935c583ef8f33bb25eab1932e52575e9926c1804';

export function relayUrl(): string {
  return `ws://${RELAY_HOST}:${RELAY_PORT}${RELAY_PATH}`;
}
