import { useEffect } from 'react';
import { AppState } from 'react-native';

import SelfAdb from './client';

/** How often we re-probe the on-device daemon while we believe we're connected. */
const DAEMON_POLL_MS = 5_000;

/**
 * While the boot state says we're connected, make sure the on-device daemon is actually alive.
 * It doesn't survive a reboot, and a launch can silently fail (a false "ready"), leaving the
 * bridge looping ECONNREFUSED with no signal. Probe it; after two confirmed misses, call
 * `refresh` (autoStart) -> it self-heals (re-enable wireless debugging + redeploy -> back to
 * 'ready') or surfaces the reconnect/pair screen via 'need-connect'/'need-pair'.
 */
export function useDaemonHeartbeat(
  enabled: boolean,
  refresh: () => void,
  /** skip a probe cycle (e.g. while a refresh is already in flight) */
  skip: () => boolean,
) {
  useEffect(() => {
    if (!enabled) return;
    let misses = 0;
    let cancelled = false;

    const check = async () => {
      if (cancelled || skip()) return;
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
        refresh();
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
    // skip is a stable ref-reader; deliberately not a dependency.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled, refresh]);
}
