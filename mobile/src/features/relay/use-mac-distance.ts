import { useEffect, useState } from 'react';

import SelfAdb from '@/features/selfadb/client';
import type { StatEvent } from '../../../modules/selfadb/src/SelfAdb.types';

export type MacDistance = {
  /** whether the Mac currently judges this phone in range */
  prox: 'near' | 'away';
  /** Mac-measured signal strength (dBm), or null if it wasn't reported */
  rssi: number | null;
};

/**
 * The Mac's BLE distance to this phone, forwarded over the link. The phone can't measure this
 * itself — it only advertises a presence beacon; the Mac scans it and sends back the reading.
 *
 * `null` until a "near"/"away" reading arrives, and back to `null` when the Mac reports the beacon
 * gone ("off"/"unseen") or proximity auto-lock is off. A battery-only `stat` (no `prox` field)
 * leaves the value untouched, so the two telemetry kinds don't clobber each other. Mirrors
 * `useMacBattery`: subscribe first, then seed from the retained native state.
 */
export function useMacDistance(): { distance: MacDistance | null } {
  const [distance, setDistance] = useState<MacDistance | null>(null);

  useEffect(() => {
    const apply = (e: StatEvent) => {
      if (e.prox === undefined) return; // battery-only frame: leave the distance as-is
      if (e.prox === 'near' || e.prox === 'away') {
        setDistance({ prox: e.prox, rssi: typeof e.rssi === 'number' ? e.rssi : null });
      } else {
        setDistance(null); // "off" | "unseen" → nothing to show
      }
    };
    const sub = SelfAdb.addListener('onMacStat', apply);
    SelfAdb.getMacStat()
      .then((s) => {
        if (s) apply(s);
      })
      .catch(() => {});
    return () => {
      sub.remove();
    };
  }, []);

  return { distance };
}

/** UI label for a distance reading, e.g. "Nearby (−67 dBm)" (or "Away" with no signal). Mirrors the
 *  Mac dashboard's `ProximityMonitor.distanceText` format. */
export function macDistanceLabel(d: MacDistance): string {
  const word = d.prox === 'near' ? 'Nearby' : 'Away';
  return d.rssi != null ? `${word} (${d.rssi} dBm)` : word;
}
