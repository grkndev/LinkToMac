import * as SecureStore from 'expo-secure-store';

const STORAGE_KEY = 'linktomac.pairing';

/**
 * Shared secret from pairing. `room` is the relay bearer; `key` is the E2E secret (used
 * later); `name` is the Mac's computer name (missing on pairings scanned before it was
 * added to the QR).
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

/**
 * Parse a scanned QR payload from the Mac: `{"v":1,"room":"...","key":"...","name":"..."}`.
 * Returns null for anything that isn't a valid v1 pairing (incl. relay's 16–128 char room).
 * `name` is optional for QRs generated before it existed.
 */
export function parsePairingQR(data: string): Pairing | null {
  try {
    const obj = JSON.parse(data) as { v?: unknown; room?: unknown; key?: unknown; name?: unknown };
    if (
      obj.v === 1 &&
      typeof obj.room === 'string' &&
      typeof obj.key === 'string' &&
      obj.room.length >= 16 &&
      obj.room.length <= 128
    ) {
      return {
        room: obj.room,
        key: obj.key,
        ...(typeof obj.name === 'string' && obj.name.length > 0 ? { name: obj.name } : {}),
      };
    }
  } catch {
    // fall through
  }
  return null;
}
