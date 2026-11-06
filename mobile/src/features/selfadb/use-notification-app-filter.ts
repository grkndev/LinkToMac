import { useFocusEffect } from 'expo-router';
import { useCallback, useEffect, useRef, useState } from 'react';

import SelfAdb, { type InstalledApp, type NotifFilterMode } from './client';

/**
 * The "Select apps" screen's per-app mirroring filter state: seeds the launcher-app list and
 * the persisted filter from the native side on mount, and exposes optimistic mutators that
 * fire-and-forget the full filter back to SharedPreferences (the NotificationListener reads
 * it live per post, so there's nothing to restart).
 *
 * Both modes keep their own selection set, so flipping include/exclude and back never loses
 * what the user picked in the other mode. A row's checkmark should always answer "will this
 * app's notifications reach the Mac?" — mode 'include' ? include.has(pkg) : !exclude.has(pkg),
 * not raw set membership.
 *
 * `setMode`/`toggleApp` have STABLE identities (latest state read through a ref): the screen
 * memoizes each of the ~100 Compose app rows on them, so a single row toggle re-renders one
 * row, not the whole list.
 */
export function useNotificationAppFilter() {
  const [apps, setApps] = useState<InstalledApp[] | null>(null);
  const [mode, setModeState] = useState<NotifFilterMode>('exclude');
  const [include, setInclude] = useState<Set<string>>(new Set());
  const [exclude, setExclude] = useState<Set<string>>(new Set());

  // Latest state for the stable callbacks below, synced post-commit (a user event can only
  // fire after the effect has run, so the callbacks never read a stale snapshot).
  const state = useRef({ mode, include, exclude });
  useEffect(() => {
    state.current = { mode, include, exclude };
  });

  useEffect(() => {
    // App-owned state that only changes through this screen — reading once on mount is enough
    // (the same convention as usePermissionSettings' prefs reads).
    SelfAdb.getInstalledApps()
      .then(setApps)
      .catch(() => setApps([]));
    SelfAdb.getNotifAppFilter()
      .then((f) => {
        setModeState(f.mode);
        setInclude(new Set(f.include));
        setExclude(new Set(f.exclude));
      })
      .catch(() => {});
  }, []);

  const setMode = useCallback((m: NotifFilterMode) => {
    setModeState(m);
    const { include, exclude } = state.current;
    persist(m, include, exclude);
  }, []);

  /** Flip whether `pkg` is mirrored, mutating whichever set the active mode enforces. */
  const toggleApp = useCallback((pkg: string) => {
    const { mode, include, exclude } = state.current;
    const next = new Set(mode === 'include' ? include : exclude);
    if (next.has(pkg)) next.delete(pkg);
    else next.add(pkg);
    if (mode === 'include') {
      setInclude(next);
      persist(mode, next, exclude);
    } else {
      setExclude(next);
      persist(mode, include, next);
    }
  }, []);

  return { apps, mode, setMode, include, exclude, toggleApp };
}

function persist(mode: NotifFilterMode, include: Set<string>, exclude: Set<string>) {
  SelfAdb.setNotifAppFilter(mode, [...include], [...exclude]).catch(() => {});
}

/**
 * One-line summary of the persisted per-app filter for the Notifications screen's "Select apps"
 * row: "All apps · 3 kept off your Mac" / "Only 5 apps". Reads just the saved sets (not the
 * installed-app list, which is heavy) and re-reads whenever the screen regains focus, so it is
 * right again after coming back from the picker. `null` until the first read.
 */
export function useNotifFilterSummary(): string | null {
  const [summary, setSummary] = useState<string | null>(null);
  useFocusEffect(
    useCallback(() => {
      let alive = true;
      SelfAdb.getNotifAppFilter()
        .then((f) => {
          if (!alive) return;
          if (f.mode === 'include') {
            const n = f.include.length;
            setSummary(n === 0 ? 'Only selected apps · none yet' : `Only ${n} app${n === 1 ? '' : 's'}`);
          } else {
            const n = f.exclude.length;
            setSummary(n === 0 ? 'All apps' : `All apps · ${n} kept off your Mac`);
          }
        })
        .catch(() => {});
      return () => {
        alive = false;
      };
    }, []),
  );
  return summary;
}
