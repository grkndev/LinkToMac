import { useEffect } from 'react';

import SelfAdb from '@/features/selfadb/client';

import { loadPairing } from './pairing-store';
import { RELAY_TOKEN, relayUrl } from './relay-config';

/**
 * On app start, if paired, push the relay config (url/token/room) to the native foreground
 * service so it connects regardless of whether the user opens the Relay tab. Native persists
 * it, so a later app-killed START_STICKY restart reconnects with no JS. Calling this every
 * launch also refreshes the dev-server-derived Mac IP.
 */
export function useRelayAutostart(): void {
  useEffect(() => {
    loadPairing()
      .then((pairing) => {
        if (pairing) return SelfAdb.setRelay(relayUrl(), RELAY_TOKEN, pairing.room, pairing.name ?? null);
      })
      .catch(() => {});

    // Android 13+: without POST_NOTIFICATIONS the foreground service runs but its
    // sticky status notification is silently hidden — ask on boot.
    SelfAdb.hasPostNotifications()
      .then((granted) => {
        if (!granted) return SelfAdb.requestPostNotifications().then(() => undefined);
      })
      .catch(() => {});
  }, []);
}
