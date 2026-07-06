import { useEffect, useState } from 'react';

import SelfAdb, { type StatEvent } from '@/features/selfadb/client';

/**
 * Base for the Mac-telemetry hooks: subscribe to `onMacStat`, then seed from the retained
 * native state (subscribe first so no push slips between the two). `stat` fields are all
 * optional and frames are partial (battery-only, proximity-only), so each consumer's `apply`
 * decides whether a frame touches its slice of state — returning `undefined` leaves the
 * previous value untouched.
 */
export function useMacStat<T>(apply: (e: StatEvent, prev: T | null) => T | null | undefined): T | null {
  const [value, setValue] = useState<T | null>(null);

  useEffect(() => {
    const onStat = (e: StatEvent) =>
      setValue((prev) => {
        const next = apply(e, prev);
        return next === undefined ? prev : next;
      });
    const sub = SelfAdb.addListener('onMacStat', onStat);
    SelfAdb.getMacStat()
      .then((s) => {
        if (s) onStat(s);
      })
      .catch(() => {});
    return () => {
      sub.remove();
    };
    // `apply` is a pure selector; deliberately not a dependency so consumers can pass inline fns.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return value;
}
