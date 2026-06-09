import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState } from 'react-native';

import SelfAdb, { CLIP_PORT } from './client';

export type BootState =
  | 'booting' // first autoStart in flight
  | 'need-pair' // never paired -> show PairScreen (pair mode)
  | 'need-connect' // paired but wireless debugging unreachable -> PairScreen (reconnect mode)
  | 'pairing' // pairAuto in flight
  | 'ready' // running, show the app
  | 'error';

export type ClipBoot = {
  state: BootState;
  error: string | null;
  /** re-run autoStart (e.g. after the user enabled wireless debugging) */
  refresh: () => Promise<void>;
  /** first-time pairing with the 6-digit code from the system dialog */
  pair: (code: string) => Promise<void>;
};

/**
 * Drives the self-ADB pipeline up at app launch with zero taps. Maps the native
 * autoStart() result to a screen the root layout gates on. Re-checks whenever
 * the app returns to the foreground (covers the user toggling wireless
 * debugging in system settings).
 */
export function useClipBoot(): ClipBoot {
  const [state, setState] = useState<BootState>('booting');
  const [error, setError] = useState<string | null>(null);
  const busy = useRef(false);
  const stateRef = useRef(state);
  stateRef.current = state;

  const refresh = useCallback(async () => {
    if (busy.current) return;
    busy.current = true;
    setError(null);
    try {
      const result = await SelfAdb.autoStart(CLIP_PORT);
      setState(result === 'ready' ? 'ready' : result); // 'need-pair' | 'need-connect'
    } catch (e: any) {
      setError(e?.message ?? String(e));
      setState('error');
    } finally {
      busy.current = false;
    }
  }, []);

  const pair = useCallback(async (code: string) => {
    if (busy.current) return;
    busy.current = true;
    setState('pairing');
    setError(null);
    try {
      await SelfAdb.pairAuto(code, CLIP_PORT);
      setState('ready');
    } catch (e: any) {
      setError(e?.message ?? String(e));
      setState('need-pair');
    } finally {
      busy.current = false;
    }
  }, []);

  useEffect(() => {
    refresh();
    const sub = AppState.addEventListener('change', (next) => {
      // On return to foreground, retry the recoverable states. Don't disturb a
      // ready session or an in-progress pair/connect.
      if (next !== 'active') return;
      if (stateRef.current === 'need-connect' || stateRef.current === 'error') {
        refresh();
      }
    });
    return () => sub.remove();
  }, [refresh]);

  return { state, error, refresh, pair };
}
