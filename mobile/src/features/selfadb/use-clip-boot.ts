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

/** How often we re-probe the on-device daemon while we believe we're connected. */
const DAEMON_POLL_MS = 5_000;

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

    // The busy gate must follow the NATIVE promise, not the UI timeout race below: a timed-out
    // autoStart keeps running inside the single shared AdbManager, and starting a second one
    // would interleave connect/deploy on the same adb session (issue #5's failure class). The
    // 20s timeout only flips UI state; the gate frees when the native call truly settles.
    const native = SelfAdb.autoStart(CLIP_PORT);
    let timedOut = false;
    native
      .then((result) => {
        // Late result after a timeout: a late 'ready' heals the UI; only touch the
        // recoverable states so we never disturb an in-progress pair.
        if (timedOut && (stateRef.current === 'need-connect' || stateRef.current === 'error')) {
          setState(result === 'ready' ? 'ready' : result);
        }
      })
      .catch((e: any) => {
        // Late failure after a timeout: stay on the recoverable screen, surface the reason.
        if (timedOut) setError(e?.message ?? String(e));
      })
      .finally(() => {
        busy.current = false;
      });

    try {
      const result = await withTimeout(native, AUTOSTART_TIMEOUT_MS, 'autoStart');
      setState(result === 'ready' ? 'ready' : result); // 'need-pair' | 'need-connect'
    } catch (e: any) {
      setError(e?.message ?? String(e));
      // A stall only happens past isPaired(), in the connect/deploy phase, so the
      // device is paired — route to the recoverable reconnect screen (which the
      // foreground-resume effect retries once the native call settles) instead of
      // stranding on the spinner.
      if (e instanceof TimeoutError) {
        timedOut = true;
        setState('need-connect');
      } else {
        setState('error');
      }
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

  // While we believe we're connected, make sure the on-device daemon is actually alive. It
  // doesn't survive a reboot, and a launch can silently fail (a false "ready"), leaving the
  // bridge looping ECONNREFUSED with no signal. Probe it; after two confirmed misses, re-run
  // autoStart -> it self-heals (re-enable wireless debugging + redeploy -> back to 'ready')
  // or surfaces the reconnect/pair screen via 'need-connect'/'need-pair'.
  useEffect(() => {
    if (state !== 'ready') return;
    let misses = 0;
    let cancelled = false;

    const check = async () => {
      if (cancelled || busy.current) return; // a refresh is already in flight
      if (AppState.currentState !== 'active') return; // the foreground service owns background recovery
      let alive = false;
      try {
        alive = await SelfAdb.isDaemonAlive();
      } catch {
        alive = false;
      }
      if (cancelled) return;
      if (alive) {
        misses = 0;
        return;
      }
      if (++misses >= 2) {
        misses = 0;
        refresh(); // autoStart -> 'ready' (silent heal) | 'need-connect' | 'need-pair'
      }
    };

    const interval = setInterval(check, DAEMON_POLL_MS);
    const sub = AppState.addEventListener('change', (next) => {
      if (next === 'active') check();
    });
    return () => {
      cancelled = true;
      clearInterval(interval);
      sub.remove();
    };
  }, [state, refresh]);

  return { state, error, refresh, pair };
}
