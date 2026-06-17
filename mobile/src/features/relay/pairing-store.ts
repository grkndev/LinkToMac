import * as SecureStore from 'expo-secure-store';

import type { ServerConfig } from './server-config';

const STORAGE_KEY = 'linktomac.pairing';

/**
 * Shared secret from pairing. `room` is the relay bearer; `key` is the 32-byte secret the
 * native E2E ClipCodec (ChaCha20-Poly1305) uses to encrypt clips; `name` is the Mac's
 * computer name (missing on pairings scanned before it was added to the QR).
 */
export type Pairing = { room: string; key: string; name?: string };

export async function loadPairing(): Promise<Pairing | null> {
  const raw = await SecureStore.getItemAsync(STORAGE_KEY);
  if (!raw) return null;
  try {
    const obj = JSON.parse(raw) as Partial<Pairing>;
    if (typeof obj.room === 'string' && typeof obj.key === 'string') {
      return {
        room: obj.room,
        key: obj.key,
        ...(typeof obj.name === 'string' ? { name: obj.name } : {}),
      };
    }
  } catch {
    // fall through
  }
  return null;
}

export async function savePairing(pairing: Pairing): Promise<void> {
  await SecureStore.setItemAsync(STORAGE_KEY, JSON.stringify(pairing));
}

export async function clearPairing(): Promise<void> {
  await SecureStore.deleteItemAsync(STORAGE_KEY);
}

/** Result of scanning the Mac's QR: the pairing plus, for a v2 QR, the relay server config. */
export type PairingScan = { pairing: Pairing; server: ServerConfig | null };

/**
 * Parse a scanned QR payload from the Mac. Accepts:
 *   v1: `{"v":1,"room","key","name"}` — pairing only (legacy; server stays default/stored).
 *   v2: `{"v":2,"room","key","name","host","port","secure","token","fp"?}` — also carries the
 *       relay server config so the phone auto-configures the endpoint + password on scan.
 * Returns null for anything that isn't a valid pairing (incl. relay's 16–128 char room).
 */
export function parsePairingQR(data: string): PairingScan | null {
  try {
    const obj = JSON.parse(data) as Record<string, unknown>;
    if (
      (obj.v !== 1 && obj.v !== 2) ||
      typeof obj.room !== 'string' ||
      typeof obj.key !== 'string' ||
      obj.room.length < 16 ||
      obj.room.length > 128
    ) {
      return null;
    }
    const pairing: Pairing = {
      room: obj.room,
      key: obj.key,
      ...(typeof obj.name === 'string' && obj.name.length > 0 ? { name: obj.name } : {}),
    };
    let server: ServerConfig | null = null;
    if (obj.v === 2 && typeof obj.host === 'string' && obj.host.length > 0 && typeof obj.port === 'number') {
      server = {
        host: obj.host,
        port: obj.port,
        secure: typeof obj.secure === 'boolean' ? obj.secure : true,
        token: typeof obj.token === 'string' ? obj.token : '',
        ...(typeof obj.fp === 'string' ? { certFingerprint: obj.fp } : {}),
      };
    }
    return { pairing, server };
  } catch {
    // fall through
  }
  return null;
}
