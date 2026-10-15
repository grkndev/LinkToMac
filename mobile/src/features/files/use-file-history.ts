import { useCallback, useEffect, useState } from 'react';
import { ToastAndroid } from 'react-native';

import SelfAdb, { type FileTransferEntry } from '@/features/selfadb/client';

/** Replace the entry with the same id in place (so a row doesn't jump while it progresses), else put it on top. */
export function upsertEntry(list: FileTransferEntry[], entry: FileTransferEntry): FileTransferEntry[] {
  const at = list.findIndex((e) => e.id === entry.id);
  if (at < 0) return [entry, ...list];
  const next = list.slice();
  next[at] = entry;
  return next;
}

/**
 * The Files screen's data: everything the foreground service has recorded (seeded from native,
 * which keeps it across restarts and while the app is swiped away), kept live by `onFileTransfer`.
 * Returns `null` items while the first fetch is in flight, distinct from "no transfers yet".
 */
export function useFileHistory() {
  const [items, setItems] = useState<FileTransferEntry[] | null>(null);

  useEffect(() => {
    let cancelled = false;
    SelfAdb.getFileHistory()
      .then((seed) => {
        if (cancelled) return;
        // An event that landed while the fetch was in flight is newer than the seed: keep it in
        // front and drop the seed's older copy of the same row.
        setItems((prev) => {
          if (!prev?.length) return seed;
          const live = new Set(prev.map((e) => e.id));
          return [...prev, ...seed.filter((e) => !live.has(e.id))];
        });
      })
      .catch(() => {
        if (!cancelled) setItems((prev) => prev ?? []);
      });

    const sub = SelfAdb.addListener('onFileTransfer', (e) => setItems((prev) => upsertEntry(prev ?? [], e)));
    return () => {
      cancelled = true;
      sub.remove();
    };
  }, []);

  const clear = useCallback(() => {
    SelfAdb.clearFileHistory().catch(() => {});
    setItems([]);
  }, []);

  const open = useCallback((entry: FileTransferEntry) => {
    if (!entry.uri) return;
    SelfAdb.openFile(entry.uri, entry.mime)
      .then((ok) => {
        if (!ok) ToastAndroid.show('No app can open this file', ToastAndroid.SHORT);
      })
      .catch(() => {});
  }, []);

  const retry = useCallback((entry: FileTransferEntry) => {
    SelfAdb.retryFileSend(entry.id).catch(() => {});
  }, []);

  const cancel = useCallback(() => {
    SelfAdb.cancelFileSend().catch(() => {});
  }, []);

  return { items, clear, open, retry, cancel };
}
