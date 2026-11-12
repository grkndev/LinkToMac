import { Column, Row } from '@expo/ui/jetpack-compose';
import { fillMaxSize, fillMaxWidth, padding, weight } from '@expo/ui/jetpack-compose/modifiers';
import { router } from 'expo-router';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Share } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { ToolButton } from '@/components/buttons';
import { useIcons } from '@/components/icons';
import { LogView } from '@/components/log-view';
import { useM3Colors } from '@/components/m3';
import { M3Host } from '@/components/m3-screen';
import { Spacing } from '@/constants/theme';
import { sanitizeLines } from '@/features/diagnostics/sanitize';
import { useKnownValues } from '@/features/diagnostics/use-known-values';
import SelfAdb from '@/features/selfadb/client';

const MAX_LINES = 500;

type LogLine = { id: number; text: string };

function clock(): string {
  return new Date().toTimeString().slice(0, 8); // HH:mm:ss — matches the native buffer format
}

/**
 * Debug console for the clipboard pipeline (the JS/native app side). Seeds from the native log
 * ring buffer (retained across the JS-runtime gap) and then appends live
 * onLog/onStatus/onRelay/onClip events. The privileged daemon's OWN on-device log — plus the
 * Restart-daemon action — lives on the separate "Daemon Log" screen (`daemon-logs.tsx`).
 *
 * Privacy: `lines` holds the raw log, but nothing raw leaves this screen. What is drawn and what
 * Share sends both go through `sanitizeLines` (so a screenshot is as safe as an export); only a
 * `__DEV__` build draws the raw text, so a developer can still read their own clipboard lines.
 * Share is sanitized even there.
 */
export default function LogsScreen() {
  const colors = useM3Colors();
  const icons = useIcons();
  const insets = useSafeAreaInsets();
  const known = useKnownValues();
  // Newest-first: index 0 is the latest line, so the list reads top-down with no per-render
  // reverse and no forced scroll — maintainVisibleContentPosition keeps the reader in place.
  const [lines, setLines] = useState<LogLine[]>([]);
  const idRef = useRef(0); // monotonic, so every line gets a stable unique key

  const append = useCallback((text: string) => {
    setLines((prev) => {
      const next = prev.length >= MAX_LINES ? prev.slice(0, MAX_LINES - 1) : prev;
      return [{ id: idRef.current++, text }, ...next];
    });
  }, []);

  useEffect(() => {
    SelfAdb.getLogs()
      .then((seed) => {
        const texts = seed.length ? seed : ['(no logs yet)'];
        const seedLines = texts.map((text) => ({ id: idRef.current++, text })).reverse();
        // Functional merge: live events that arrived while getLogs() was in flight are newer
        // than the snapshot — keep them in front instead of overwriting them away.
        setLines((prev) => (prev.length ? [...prev, ...seedLines] : seedLines));
      })
      .catch(() => {});

    const log = SelfAdb.addListener('onLog', (e) => append(`${clock()}  ${e.message}`));
    const status = SelfAdb.addListener('onStatus', (e) =>
      append(`${clock()}  status: adb=${e.adb} clip=${e.clip}`),
    );
    const relay = SelfAdb.addListener('onRelay', (e) =>
      append(
        `${clock()}  relay: ${e.status} · peer=${e.peerOnline ? 'online' : 'offline'}` +
          (e.lastError ? ` · ${e.lastError}` : ''),
      ),
    );
    // Length only: the clipboard text itself is never written to a log line (see sanitize.ts).
    const clip = SelfAdb.addListener('onClip', (e) =>
      append(`${clock()}  clip ⬆ (${e.text.length} chars)`),
    );
    return () => {
      log.remove();
      status.remove();
      relay.remove();
      clip.remove();
    };
  }, [append]);

  // Newest-first, sanitized — except in a dev build, which shows its own raw log on screen.
  const shown = useMemo(() => {
    const texts = lines.map((l) => l.text);
    return __DEV__ ? texts : sanitizeLines(texts, known);
  }, [lines, known]);

  const shareAll = useCallback(() => {
    const clean = sanitizeLines(
      lines.map((l) => l.text),
      known,
    ).reverse();
    const body = ['=== Application Logs ===', ...clean].join('\n');
    Share.share({ message: body }).catch(() => {});
  }, [lines, known]);

  const clear = useCallback(() => {
    SelfAdb.clearLogs().catch(() => {});
    setLines([]);
  }, []);

  return (
    <M3Host>
      <Column
        modifiers={[
          fillMaxSize(),
          padding(Spacing.three, Spacing.one, Spacing.three, insets.bottom + Spacing.three),
        ]}
        verticalArrangement={{ spacedBy: 12 }}
      >
        <Row modifiers={[fillMaxWidth()]} horizontalArrangement={{ spacedBy: Spacing.two }}>
          <ToolButton
            colors={colors}
            icon={icons.terminal}
            label="Daemon log"
            grow
            onPress={() => router.push('/daemon-logs')}
          />
          <ToolButton colors={colors} icon={icons.share} tone="neutral" onPress={shareAll} />
          <ToolButton colors={colors} icon={icons.delete} tone="error" onPress={clear} />
        </Row>
        <Column modifiers={[fillMaxWidth(), weight(1)]}>
          <LogView colors={colors} lines={shown} empty="(no logs yet)" />
        </Column>
      </Column>
    </M3Host>
  );
}
