import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState } from 'react-native';

import { TimeoutError, withTimeout } from '@/lib/async';
import SelfAdb, { CLIP_PORT, type AutoStartState } from './client';
import { useDaemonHeartbeat } from './use-daemon-heartbeat';

/**
 * Hard ceiling for a single autoStart(). The native call has bounded timeouts on
 * probe (400ms) and mDNS discover (8s), but adb's TLS connect + exec streams
 * (dex push, daemon launch) have none — a half-trusted adbd (common on Samsung
 * after a wireless-debugging toggle/reboot) can stall them forever. Without this
 * the state never leaves 'starting' and the setup screen hangs on the spinner.
 */
const AUTOSTART_TIMEOUT_MS = 20_000;

/**
 * Health of the *automatic* clipboard capture path (self-ADB -> shell-UID daemon), which is
 * the only thing ADB buys us. Deliberately NOT a boot state: nothing here gates the app.
 * Everything else — the relay/LAN link, remote lock, battery telemetry, notification + SMS
 * mirroring, Mac->phone clipboard — runs without ADB and keeps working at every value below.
 */
export type CaptureState =
  | 'starting' // first autoStart in flight
  | 'live' // daemon deployed + bridge up -> copies are captured automatically
  | 'needs-setup' // ADB can't bring the daemon up right now; see `reason`
  | 'pairing' // pairAuto in flight
  | 'error';

/** Why `needs-setup` — decides which half of the setup screen to show. */
export type CaptureSetupReason =
  | 'never-paired' // no adb pairing key yet -> collect the 6-digit code
  | 'debugging-unreachable'; // paired, but wireless debugging is off/untrusted -> retry

export type ClipBoot = {
  state: CaptureState;
  /** Only meaningful while `state` is 'needs-setup'; null otherwise. */
  reason: CaptureSetupReason | null;
  error: string | null;
  /** true while a refresh() is in flight (up to the UI timeout) — drive Try Again's
   *  spinner/disabled state so a tap never looks like a no-op (issue #30). */
  refreshing: boolean;
  /** re-run autoStart (e.g. after the user enabled wireless debugging) */
  refresh: () => Promise<void>;
  /** first-time pairing with the 6-digit code from the system dialog */
  pair: (code: string) => Promise<void>;
};

/** State and reason move together, so they live in one value — a single source of truth for
 *  both the render and the ref the async callbacks read. */
type Capture = { state: CaptureState; reason: CaptureSetupReason | null };

/** Native autoStart() result -> capture health. */
function fromNative(result: AutoStartState): Capture {
  if (result === 'ready') return { state: 'live', reason: null };
  if (result === 'need-pair') return { state: 'needs-setup', reason: 'never-paired' };
  return { state: 'needs-setup', reason: 'debugging-unreachable' };
}

/** Whether a late/foreground retry may overwrite the current value without stomping on
 *  an in-progress pair or a healthy session. */
function recoverable({ state, reason }: Capture): boolean {
  return state === 'error' || (state === 'needs-setup' && reason === 'debugging-unreachable');
}

/**
 * Drives the self-ADB pipeline up at app launch with zero taps, in the background. Maps the
 * native autoStart() result onto a capture health state the UI *reports* (banner + setup
 * screen) rather than gates on. Re-checks whenever the app returns to the foreground (covers
 * the user toggling wireless debugging in system settings).
 */
export function useClipBoot(): ClipBoot {
  const [capture, setCapture] = useState<Capture>({ state: 'starting', reason: null });
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const busy = useRef(false);
  const captureRef = useRef(capture);
  captureRef.current = capture;

  const refresh = useCallback(async () => {
    if (busy.current) return;
    busy.current = true;
    setRefreshing(true);
    setError(null);

    // The busy gate must follow the NATIVE promise, not the UI timeout race below: a timed-out
    // autoStart keeps running inside the single shared AdbManager, and starting a second one
    // would interleave connect/deploy on the same adb session (issue #5's failure class). The
    // 20s timeout only flips UI state; the gate frees when the native call truly settles.
    const native = SelfAdb.autoStart(CLIP_PORT);
    let timedOut = false;
    native
      .then((result) => {
        // Late result after a timeout: a late 'live' heals the UI; only touch the
        // recoverable states so we never disturb an in-progress pair.
        if (timedOut && recoverable(captureRef.current)) setCapture(fromNative(result));
      })
      .catch((e: any) => {
        // Late failure after a timeout: stay on the recoverable state, surface the reason.
        if (timedOut) setError(e?.message ?? String(e));
      })
      .finally(() => {
        busy.current = false;
      });

    try {
      setCapture(fromNative(await withTimeout(native, AUTOSTART_TIMEOUT_MS, 'autoStart')));
    } catch (e: any) {
      setError(e?.message ?? String(e));
      // A stall only happens past isPaired(), in the connect/deploy phase, so the
      // device is paired — land on the recoverable reason (which the foreground-resume
      // effect retries once the native call settles) instead of stranding on 'starting'.
      if (e instanceof TimeoutError) {
        timedOut = true;
        setCapture({ state: 'needs-setup', reason: 'debugging-unreachable' });
        // Force-wake the still-running native autoStart (closes the adb session) instead of
        // leaving it to fail on its own internal watchdog — makes the very next Try Again
        // responsive instead of racing whatever's left of autoStart's own bound. cancelAdb runs
        // on the native module's default queue, so it's reachable even while autoStart occupies
        // the dedicated ADB queue (see SelfAdbModule.kt).
        SelfAdb.cancelAdb().catch(() => {});
      } else {
        setCapture({ state: 'error', reason: null });
      }
    } finally {
      // Only covers the UI-visible portion of this refresh (up to the 20s timeout) — the
      // native promise may keep running past this and is tracked separately by `busy`.
      setRefreshing(false);
    }
  }, []);

  const pair = useCallback(async (code: string) => {
    if (busy.current) return;
    busy.current = true;
    setCapture({ state: 'pairing', reason: null });
    setError(null);
    try {
      await SelfAdb.pairAuto(code, CLIP_PORT);
      setCapture({ state: 'live', reason: null });
    } catch (e: any) {
      setError(e?.message ?? String(e));
      setCapture({ state: 'needs-setup', reason: 'never-paired' });
    } finally {
      busy.current = false;
    }
  }, []);

  useEffect(() => {
    refresh();
    const sub = AppState.addEventListener('change', (next) => {
      // On return to foreground, retry the recoverable states. Don't disturb a
      // live session or an in-progress pair/connect.
      if (next !== 'active') return;
      if (recoverable(captureRef.current)) refresh();
    });
    return () => sub.remove();
  }, [refresh]);

  // Skip a probe while a refresh is already in flight (busy) — see use-daemon-heartbeat.
  useDaemonHeartbeat(capture.state === 'live', refresh, () => busy.current);

  return { ...capture, error, refreshing, refresh, pair };
}
