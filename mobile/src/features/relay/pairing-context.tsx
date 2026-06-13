import type { ReactNode } from 'react';
import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';

import SelfAdb from '@/features/selfadb/client';

import { clearPairing, loadPairing, savePairing, type Pairing } from './pairing-store';
import { RELAY_TOKEN, relayUrl } from './relay-config';

type PairingContextValue = {
  /** undefined while the SecureStore load is in flight. */
  pairing: Pairing | null | undefined;
  setPairing: (pairing: Pairing) => Promise<void>;
  unpair: () => Promise<void>;
  paused: boolean;
  setPaused: (paused: boolean) => void;
};

const PairingContext = createContext<PairingContextValue | null>(null);

/**
 * Single reactive source of truth for the Mac pairing. Seeds from SecureStore and
 * pushes the relay config (url/token/room/name) to the native foreground service
 * whenever a pairing exists — that covers both app launch (refreshing the
 * dev-server-derived Mac IP) and a fresh QR scan. The root layout's route guards
 * key off `pairing`, so setPairing/unpair flip the visible screen automatically.
 */
export function PairingProvider({ children }: { children: ReactNode }) {
  const [pairing, setPairingState] = useState<Pairing | null | undefined>(undefined);
  const [paused, setPausedState] = useState(false);

  useEffect(() => {
    // A SecureStore read failure must not strand `pairing` at undefined (which the
    // root layout treats as "still booting" -> permanent spinner). Fall back to
    // unpaired so the guards send the user to the pairing flow instead.
    loadPairing()
      .then(setPairingState)
      .catch(() => setPairingState(null));
  }, []);

  useEffect(() => {
    if (!pairing) return;
    SelfAdb.setRelay(relayUrl(), RELAY_TOKEN, pairing.room, pairing.name ?? null).catch(() => {});
  }, [pairing]);

  const setPairing = useCallback(async (next: Pairing) => {
    await savePairing(next);
    setPairingState(next);
  }, []);

  const unpair = useCallback(async () => {
    await clearPairing();
    await SelfAdb.clearRelay().catch(() => {});
    setPairingState(null);
    setPausedState(false);
  }, []);

  const setPaused = useCallback((next: boolean) => {
    setPausedState(next);
    SelfAdb.relaySetPaused(next).catch(() => {});
  }, []);

  const value = useMemo(
    () => ({ pairing, setPairing, unpair, paused, setPaused }),
    [pairing, setPairing, unpair, paused, setPaused],
  );

  return <PairingContext.Provider value={value}>{children}</PairingContext.Provider>;
}

export function usePairing(): PairingContextValue {
  const ctx = useContext(PairingContext);
  if (!ctx) throw new Error('usePairing must be used within a PairingProvider');
  return ctx;
}
