import { useMacStat } from './use-mac-stat';

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
 * leaves the value untouched, so the two telemetry kinds don't clobber each other.
 */
export function useMacDistance(): { distance: MacDistance | null } {
  const distance = useMacStat<MacDistance>((e) => {
    if (e.prox === undefined) return undefined; // battery-only frame: leave the distance as-is
    if (e.prox === 'near' || e.prox === 'away') {
      return { prox: e.prox, rssi: typeof e.rssi === 'number' ? e.rssi : null };
    }
    return null; // "off" | "unseen" → nothing to show
  });
  return { distance };
}

/** UI label for a distance reading, e.g. "Nearby (−67 dBm)" (or "Away" with no signal). Mirrors the
 *  Mac dashboard's `ProximityMonitor.distanceText` format. */
export function macDistanceLabel(d: MacDistance): string {
  const word = d.prox === 'near' ? 'Nearby' : 'Away';
  return d.rssi != null ? `${word} (${d.rssi} dBm)` : word;
}
