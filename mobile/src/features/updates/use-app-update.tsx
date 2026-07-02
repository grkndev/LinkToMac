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

import { checkForAppUpdate, type AppUpdate } from './check';

type PendingUpdate = Exclude<AppUpdate, { kind: 'none' } | { kind: 'failed' }>;

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
  /** Open the APK download (or release page) for a native update. */
  openDownload: () => void;
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
      setUpdate(result);
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
    // Leave fetchUpdateAsync() running; just release the dialog. The staged update
    // applies on the next app launch (see applyOta).
    background.current = true;
    setApplyingOta(false);
    setUpdate(null);
  }, []);

  const openDownload = useCallback(() => {
    // Side effect OUTSIDE the setState updater: React may invoke updaters twice (StrictMode),
    // which double-opened the download.
    if (update?.kind === 'native') Linking.openURL(update.url).catch(() => {});
    setUpdate(null);
  }, [update]);

  const dismiss = useCallback(() => setUpdate(null), []);

  return (
    <Ctx.Provider
      value={{
        update,
        checking,
        applyingOta,
        checkNow,
        applyOta,
        continueInBackground,
        openDownload,
        dismiss,
      }}
    >
      {children}
    </Ctx.Provider>
  );
}
