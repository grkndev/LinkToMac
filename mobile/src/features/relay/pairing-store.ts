import * as SecureStore from 'expo-secure-store';

const STORAGE_KEY = 'linktomac.pairing';

/** Shared secret from pairing. `room` is the relay bearer; `key` is the E2E secret (used later). */
export type Pairing = { room: string; key: string };

export async function loadPairing(): Promise<Pairing | null> {
  const raw = await SecureStore.getItemAsync(STORAGE_KEY);
  if (!raw) return null;
  try {
    const obj = JSON.parse(raw) as Partial<Pairing>;
    if (typeof obj.room === 'string' && typeof obj.key === 'string') {
      return { room: obj.room, key: obj.key };
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

/**
 * Parse a scanned QR payload from the Mac: `{"v":1,"room":"...","key":"..."}`.
 * Returns null for anything that isn't a valid v1 pairing (incl. relay's 16–128 char room).
 */
export function parsePairingQR(data: string): Pairing | null {
  try {
    const obj = JSON.parse(data) as { v?: unknown; room?: unknown; key?: unknown };
    if (
      obj.v === 1 &&
      typeof obj.room === 'string' &&
      typeof obj.key === 'string' &&
      obj.room.length >= 16 &&
      obj.room.length <= 128
    ) {
      return { room: obj.room, key: obj.key };
    }
  } catch {
    // fall through
  }
  return null;
}
