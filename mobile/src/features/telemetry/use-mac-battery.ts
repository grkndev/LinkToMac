import { useMacStat } from './use-mac-stat';

export type MacBattery = { level: number; charging: boolean };

/**
 * The Mac's battery (level + charging), as last reported over the link. `null` until a value has
 * been received — desktop Macs never send one, so it stays null there.
 *
 * `stat` frames also carry BLE proximity (see `useMacDistance`); a proximity-only frame has no
 * `level`, so those are ignored here rather than blanking the battery.
 */
export function useMacBattery(): { battery: MacBattery | null } {
  const battery = useMacStat<MacBattery>((e) =>
    typeof e.level === 'number' ? { level: e.level, charging: e.charging ?? false } : undefined,
  );
  return { battery };
}
