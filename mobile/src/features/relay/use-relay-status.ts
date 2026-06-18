import { useEffect, useState } from 'react';

import SelfAdb from '@/features/selfadb/client';

export type RelayUi = {
  status: string;
  peerOnline: boolean;
  lastError?: string | null;
  /** which transport is carrying the connection: 'lan' (direct) | 'relay' | null when down. */
  transport?: 'lan' | 'relay' | null;
  /** consecutive reconnect attempts on the active link; 0 once joined. */
  attempt?: number;
};

/**
 * Mirrors the native relay status + the last synced clipboard text for display.
 * The service may have connected long before the consumer mounted, so seed from
 * the retained native state (subscribe first so no transition slips between the two).
 */
export function useRelayStatus(): { relay: RelayUi; lastClip: string | null } {
  const [relay, setRelay] = useState<RelayUi>({ status: 'disconnected', peerOnline: false });
  const [lastClip, setLastClip] = useState<string | null>(null);

  useEffect(() => {
    const r = SelfAdb.addListener('onRelay', (e) =>
      setRelay({ status: e.status, peerOnline: e.peerOnline, lastError: e.lastError, transport: e.transport, attempt: e.attempt }),
    );
    const c = SelfAdb.addListener('onClip', (e) => setLastClip(e.text));
    SelfAdb.relayGetStatus()
      .then((e) => setRelay({ status: e.status, peerOnline: e.peerOnline, lastError: e.lastError, transport: e.transport, attempt: e.attempt }))
      .catch(() => {});
    return () => {
      r.remove();
      c.remove();
    };
  }, []);

  return { relay, lastClip };
}
