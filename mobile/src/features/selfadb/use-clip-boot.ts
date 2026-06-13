import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState } from 'react-native';

import SelfAdb, { CLIP_PORT } from './client';

/**
 * Hard ceiling for a single autoStart(). The native call has bounded timeouts on
 * probe (400ms) and mDNS discover (8s), but adb's TLS connect + exec streams
 * (dex push, daemon launch) have none — a half-trusted adbd (common on Samsung
 * after a wireless-debugging toggle/reboot) can stall them forever. Without this
 * the boot state never leaves 'booting' and the app hangs on the spinner.
 */
const AUTOSTART_TIMEOUT_MS = 20_000;

/** Distinguishes "native call stalled" from a real native error in the catch. */
class TimeoutError extends Error {}

function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new TimeoutError(`${label} ${ms} ms içinde yanıt vermedi`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

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
      const result = await withTimeout(SelfAdb.autoStart(CLIP_PORT), AUTOSTART_TIMEOUT_MS, 'autoStart');
      setState(result === 'ready' ? 'ready' : result); // 'need-pair' | 'need-connect'
    } catch (e: any) {
      setError(e?.message ?? String(e));
      // A stall only happens past isPaired(), in the connect/deploy phase, so the
      // device is paired — route to the recoverable reconnect screen (which the
      // foreground-resume effect retries) instead of stranding on the spinner.
      setState(e instanceof TimeoutError ? 'need-connect' : 'error');
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
