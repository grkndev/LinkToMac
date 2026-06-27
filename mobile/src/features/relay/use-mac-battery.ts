import { useEffect, useState } from 'react';

import SelfAdb from '@/features/selfadb/client';
import type { StatEvent } from '../../../modules/selfadb/src/SelfAdb.types';

export type MacBattery = { level: number; charging: boolean };

/**
 * The Mac's battery (level + charging), as last reported over the link. The service may have
 * received a value before this mounted, so seed from the retained native state (subscribe first
 * so no push slips between the two). `null` until a value has been received — desktop Macs never
 * send one, so it stays null there.
 *
 * `stat` frames now also carry BLE proximity (see `useMacDistance`); a proximity-only frame has no
 * `level`, so ignore those here rather than blanking the battery.
 */
export function useMacBattery(): { battery: MacBattery | null } {
  const [battery, setBattery] = useState<MacBattery | null>(null);

  useEffect(() => {
    const apply = (e: StatEvent) => {
      if (typeof e.level === 'number') {
        setBattery({ level: e.level, charging: e.charging ?? false });
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

  return { battery };
}
