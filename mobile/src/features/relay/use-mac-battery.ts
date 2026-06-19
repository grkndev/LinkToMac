import { useEffect, useState } from 'react';

import SelfAdb from '@/features/selfadb/client';
import type { StatEvent } from '../../../modules/selfadb/src/SelfAdb.types';

/**
 * The Mac's battery (level + charging), as last reported over the link. The service may have
 * received a value before this mounted, so seed from the retained native state (subscribe first
 * so no push slips between the two). `null` until a value has been received — desktop Macs never
 * send one, so it stays null there.
 */
export function useMacBattery(): { battery: StatEvent | null } {
  const [battery, setBattery] = useState<StatEvent | null>(null);

  useEffect(() => {
    const sub = SelfAdb.addListener('onMacStat', (e) =>
      setBattery({ level: e.level, charging: e.charging }),
    );
    SelfAdb.getMacStat()
      .then((s) => {
        if (s) setBattery({ level: s.level, charging: s.charging });
      })
      .catch(() => {});
    return () => {
      sub.remove();
    };
  }, []);

  return { battery };
}
