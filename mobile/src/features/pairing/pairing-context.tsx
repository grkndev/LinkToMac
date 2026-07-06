import type { ReactNode } from 'react';
import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';

import SelfAdb from '@/features/selfadb/client';

import { clearPairing, loadPairing, savePairing, type Pairing } from './pairing-store';
import {
  clearServerConfig,
  connectionArgs,
  loadServerConfig,
  saveServerConfig,
  type ServerConfig,
} from '@/features/connection/server-config';

type PairingContextValue = {
  /** undefined while the SecureStore load is in flight. */
  pairing: Pairing | null | undefined;
  /** Persisted relay server config; null when none saved yet (falls back to defaults). */
  server: ServerConfig | null | undefined;
  setPairing: (pairing: Pairing, server?: ServerConfig | null) => Promise<void>;
  setServer: (server: ServerConfig) => Promise<void>;
  unpair: () => Promise<void>;
  paused: boolean;
  setPaused: (paused: boolean) => void;
};

const PairingContext = createContext<PairingContextValue | null>(null);

/**
 * Single reactive source of truth for the Mac pairing + relay server config. Seeds both from
 * SecureStore and pushes the relay config (url/token/room/name) to the native foreground
 * service whenever a pairing AND a saved ServerConfig both exist — covering app launch, a
 * fresh QR scan (v2 carries the server config), and a manual server-config edit in Settings.
 * There is no baked-in fallback: paired-but-unconfigured stays idle until the user sets the
 * server. The root layout's route guards key off `pairing`, so setPairing/unpair flip the
 * visible screen automatically.
 */
export function PairingProvider({ children }: { children: ReactNode }) {
  const [pairing, setPairingState] = useState<Pairing | null | undefined>(undefined);
  const [server, setServerState] = useState<ServerConfig | null | undefined>(undefined);
  const [paused, setPausedState] = useState(false);

  useEffect(() => {
    // A SecureStore read failure must not strand `pairing` at undefined (which the
    // root layout treats as "still booting" -> permanent spinner). Fall back to
    // unpaired so the guards send the user to the pairing flow instead.
    loadPairing()
      .then(setPairingState)
      .catch(() => setPairingState(null));
    loadServerConfig()
      .then(setServerState)
      .catch(() => setServerState(null));
    // Seed the send gate from the persisted native value so it survives app/service restarts.
    SelfAdb.relayIsSendPaused().then(setPausedState).catch(() => {});
  }, []);

  useEffect(() => {
    if (!pairing) return;
    // No baked-in server: connect only once a ServerConfig has been saved (from a QR scan or
    // Settings -> Relay server). `undefined` = still loading; `null` = paired but unconfigured
    // (e.g. a legacy v1 QR) -> stay idle until the user sets the server. The config may carry a
    // relay endpoint, the LAN-direct params, or both — `connectionArgs` derives all of them.
    if (!server) return;
    const c = connectionArgs(server);
    SelfAdb.setRelay(c.url, c.token, pairing.room, pairing.key, pairing.name ?? null, c.lanEnabled, c.lanPort, c.lanHost).catch(() => {});
  }, [pairing, server]);

  const setPairing = useCallback(async (next: Pairing, nextServer?: ServerConfig | null) => {
    await savePairing(next);
    if (nextServer) {
      await saveServerConfig(nextServer);
      setServerState(nextServer);
    }
    setPairingState(next);
  }, []);

  const setServer = useCallback(async (next: ServerConfig) => {
    await saveServerConfig(next);
    setServerState(next);
  }, []);

  const unpair = useCallback(async () => {
    await clearPairing();
    await clearServerConfig();
    await SelfAdb.clearRelay().catch(() => {});
    setPairingState(null);
    setServerState(null);
    setPausedState(false);
  }, []);

  const setPaused = useCallback(async (next: boolean) => {
    // Optimistic flip for a snappy toggle, but roll back if the native gate rejects —
    // otherwise the UI shows "paused" while clips keep flowing (or vice versa) until relaunch.
    setPausedState(next);
    try {
      await SelfAdb.relaySetPaused(next);
    } catch {
      setPausedState(!next);
    }
  }, []);

  const value = useMemo(
    () => ({ pairing, server, setPairing, setServer, unpair, paused, setPaused }),
    [pairing, server, setPairing, setServer, unpair, paused, setPaused],
  );

  return <PairingContext.Provider value={value}>{children}</PairingContext.Provider>;
}

export function usePairing(): PairingContextValue {
  const ctx = useContext(PairingContext);
  if (!ctx) throw new Error('usePairing must be used within a PairingProvider');
  return ctx;
}
