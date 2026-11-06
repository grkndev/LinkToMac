import * as Updates from 'expo-updates';
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import { Alert, Linking } from 'react-native';

import SelfAdb from '@/features/selfadb/client';

import { checkForAppUpdate, toNativeUpdate, type AppUpdate } from './check';

export type PendingUpdate = Exclude<AppUpdate, { kind: 'none' } | { kind: 'failed' }>;

type UpdateState = {
  /** The pending update to surface in the modal, or null when nothing is pending / dismissed. */
  update: PendingUpdate | null;
  /** A check is in flight (drives the About row's "Checking…" hint). */
  checking: boolean;
  /** An OTA download is in flight (drives the "App is updating" dialog + progress bar). */
  applyingOta: boolean;
  /** Re-run a check. `manual` surfaces "up to date" / "failed" feedback (the About button). */
  checkNow: (manual?: boolean) => Promise<void>;
  /** Download + reload an OTA update in place (shows the "App is updating" dialog). */
  applyOta: () => Promise<void>;
  /** Let the in-flight OTA download finish in the background; it applies on the next launch. */
  continueInBackground: () => void;
  /**
   * The native update's primary action. Ready → open the system installer (the user confirms
   * there). Downloadable but not fetched → start the in-app download; the sheet stays up and shows
   * its progress. No APK the app can fetch → the browser fallback.
   */
  startNativeUpdate: () => void;
  /** Dismiss the modal ("Later"). */
  dismiss: () => void;
};

const Ctx = createContext<UpdateState | null>(null);

export function useAppUpdate(): UpdateState {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useAppUpdate must be used within AppUpdateProvider');
  return ctx;
}

/**
 * Owns the "is there a newer version?" check and the resulting modal state for the whole app.
 * Auto-checks once per launch (release builds only); the About screen drives a manual check
 * through {@link useAppUpdate}. See {@link checkForAppUpdate} for the OTA-vs-native split.
 */
export function AppUpdateProvider({ children }: { children: ReactNode }) {
  const [update, setUpdate] = useState<PendingUpdate | null>(null);
  const [checking, setChecking] = useState(false);
  const [applyingOta, setApplyingOta] = useState(false);
  const inFlight = useRef(false);
  // Set when the user taps "Continue in background": the fetch keeps running but we
  // skip the forced reload (and stay silent on failure) since they've left the dialog.
  const background = useRef(false);
  // The version the user already waved off ("Later" / "Continue in background"): a download that
  // finishes while the app is open must not pop the sheet back up for it.
  const dismissed = useRef<string | null>(null);

  const checkNow = useCallback(async (manual = false) => {
    if (inFlight.current) return;
    inFlight.current = true;
    setChecking(true);
    try {
      const result = await checkForAppUpdate();
      if (result.kind === 'failed') {
        // The probe itself failed (offline / API error) — an auto-check stays silent.
        if (manual) Alert.alert('Check failed', "Couldn't check for updates. Try again later.");
        return;
      }
      if (result.kind === 'none') {
        if (manual) Alert.alert("You're up to date", 'No new version is available.');
        return;
      }
      // A manual check is a request to see it, so it overrides an earlier "Later".
      if (manual || result.kind !== 'native' || dismissed.current !== result.version) {
        dismissed.current = null;
        setUpdate(result);
      }
    } catch {
      if (manual) {
        Alert.alert('Check failed', "Couldn't check for updates. Try again later.");
      }
    } finally {
      inFlight.current = false;
      setChecking(false);
    }
  }, []);

  // Auto-check once per launch. Skipped in dev: OTA is disabled there and a stale native version
  // would nag on every reload while iterating. Deferred a microtask so the check (and its
  // setState) runs after the first paint rather than synchronously inside the effect.
  useEffect(() => {
    if (__DEV__) return;
    let cancelled = false;
    Promise.resolve().then(() => {
      if (!cancelled) checkNow(false);
    });
    return () => {
      cancelled = true;
    };
  }, [checkNow]);

  // The native updater reports progress/state as it works (also while the app was closed and is now
  // reopened). Patch the open sheet, or raise it when a background download just became ready.
  useEffect(() => {
    if (typeof SelfAdb.addListener !== 'function') return;
    const sub = SelfAdb.addListener('onAppUpdate', (state) => {
      const next = toNativeUpdate(state);
      setUpdate((cur) => {
        if (cur?.kind === 'native') return next ? { ...cur, ...next } : cur;
        if (cur == null && next?.state === 'ready' && dismissed.current !== next.version) return next;
        return cur;
      });
    });
    return () => sub.remove();
  }, []);

  const applyOta = useCallback(async () => {
    // Flip into the "applying" state first so the modal can show the "App is updating"
    // dialog with a progress bar — fetchUpdateAsync() has no progress callback and takes
    // a few seconds, and without this the button looks dead until reloadAsync() restarts.
    background.current = false;
    setApplyingOta(true);
    try {
      await Updates.fetchUpdateAsync();
      // If the user chose "Continue in background" mid-download, the fetched bundle is
      // already staged and expo-updates loads it on the next launch — don't force a restart.
      if (background.current) return;
      // Unmount the sheet BEFORE reloading: it renders in its own native window, and
      // reloadAsync() tears down the JS runtime without unmounting views — the dialog
      // would survive the restart, frozen on "App is updating", covering the new app.
      setApplyingOta(false);
      setUpdate(null);
      await new Promise((resolve) => setTimeout(resolve, 400)); // let the window dismiss
      await Updates.reloadAsync(); // restarts the app — nothing below runs on success
    } catch {
      // A background failure stays silent (it'll be re-offered on the next check); only
      // surface the error if the user is still watching the "App is updating" dialog.
      if (!background.current) {
        setApplyingOta(false);
        setUpdate(null);
        Alert.alert('Update failed', "Couldn't download the update. Try again later.");
      }
    }
  }, []);

  const continueInBackground = useCallback(() => {
    // Leave fetchUpdateAsync() running (or the native APK download); just release the dialog. The
    // staged OTA applies on the next launch (see applyOta); a finished APK announces itself with
    // the "Update ready" notification.
    background.current = true;
    if (update?.kind === 'native') dismissed.current = update.version;
    setApplyingOta(false);
    setUpdate(null);
  }, [update]);

  const startNativeUpdate = useCallback(() => {
    if (update?.kind !== 'native') return;
    // Side effects OUTSIDE the setState updaters: React may invoke updaters twice (StrictMode),
    // which double-fired them.
    if (update.state === 'ready') {
      SelfAdb.installAppUpdate()
        .then((opened) => {
          if (!opened) Alert.alert('Update not ready', 'The download is no longer available. Check again.');
        })
        .catch(() => Alert.alert('Update failed', "Couldn't open the installer."));
      // The system installer takes over; the sheet's job is done either way.
      dismissed.current = update.version;
      setUpdate(null);
      return;
    }
    if (update.downloadable) {
      // Flip to the downloading state now; the native events keep the progress current.
      setUpdate({ ...update, state: 'downloading', progress: 0, error: null });
      SelfAdb.downloadAppUpdate().catch(() => {});
      return;
    }
    Linking.openURL(update.url).catch(() => {});
    setUpdate(null);
  }, [update]);

  const dismiss = useCallback(() => {
    if (update?.kind === 'native') dismissed.current = update.version;
    setUpdate(null);
  }, [update]);

  return (
    <Ctx.Provider
      value={{
        update,
        checking,
        applyingOta,
        checkNow,
        applyOta,
        continueInBackground,
        startNativeUpdate,
        dismiss,
      }}
    >
      {children}
    </Ctx.Provider>
  );
}
