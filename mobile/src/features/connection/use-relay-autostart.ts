import { useEffect } from 'react';

import SelfAdb from '@/features/selfadb/client';

/**
 * Android 13+: without POST_NOTIFICATIONS the foreground service runs but its
 * sticky status notification is silently hidden — ask on boot. (The relay config
 * push lives in PairingProvider, which owns the pairing state.)
 */
export function useRelayAutostart(): void {
  useEffect(() => {
    SelfAdb.hasPostNotifications()
      .then((granted) => {
        if (!granted) return SelfAdb.requestPostNotifications().then(() => undefined);
      })
      .catch(() => {});
  }, []);
}
