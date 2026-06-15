import { useCallback, useEffect, useState } from 'react';

import SelfAdb from '@/features/selfadb/client';
import type { ClipEvent } from '../../../modules/selfadb/src/SelfAdb.types';

export type ClipItem = ClipEvent;

/**
 * History of clips received FROM the Mac. Seeds from the native retained buffer (which the
 * foreground service fills even while the app is swiped away / JS is dead), then prepends live
 * `onMacClip` events so the newest item is always first. Returns `null` while the initial fetch
 * is in flight so the screen can show a loading state distinct from "no items yet".
 */
export function useClipHistory(): { items: ClipItem[] | null; clear: () => void } {
  const [items, setItems] = useState<ClipItem[] | null>(null);

  useEffect(() => {
    let cancelled = false;
    SelfAdb.getClipHistory()
      .then((seed) => {
        if (!cancelled) setItems(seed);
      })
      .catch(() => {
        if (!cancelled) setItems([]);
      });

    const sub = SelfAdb.addListener('onMacClip', (e) =>
      setItems((prev) => [{ text: e.text, ts: e.ts }, ...(prev ?? [])]),
    );
    return () => {
      cancelled = true;
      sub.remove();
    };
  }, []);

  const clear = useCallback(() => {
    SelfAdb.clearClipHistory().catch(() => {});
    setItems([]);
  }, []);

  return { items, clear };
}
