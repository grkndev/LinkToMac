import { useCallback, useEffect, useState } from 'react';

import SelfAdb, { type ClipEvent } from '@/features/selfadb/client';

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
        if (cancelled) return;
        // Functional merge: a Mac clip that arrived while the fetch was in flight was already
        // prepended by the listener — keep it in front of the seed instead of overwriting it.
        setItems((prev) => {
          if (!prev?.length) return seed;
          const seen = new Set(prev.map((i) => `${i.ts}:${i.text}`));
          return [...prev, ...seed.filter((i) => !seen.has(`${i.ts}:${i.text}`))];
        });
      })
      .catch(() => {
        if (!cancelled) setItems((prev) => prev ?? []);
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
