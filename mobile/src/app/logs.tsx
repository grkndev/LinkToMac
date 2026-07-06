import { MaterialIcons } from '@expo/vector-icons';
import { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, FlatList, Pressable, ScrollView, Share, Text, View } from 'react-native';

import SelfAdb from '@/features/selfadb/client';
import { useTheme } from '@/hooks/use-theme';
import { preview } from '@/lib/text';

const MAX_LINES = 500;

type LogLine = { id: number; text: string };

function clock(): string {
  return new Date().toTimeString().slice(0, 8); // HH:mm:ss — matches the native buffer format
}

/**
 * Debug console for the clipboard pipeline. Seeds from the native log ring buffer
 * (retained across the JS-runtime gap) and then appends live onLog/onStatus/onRelay/onClip
 * events. "Cihaz günlüğünü getir" pulls the privileged daemon's own on-device log over adb —
 * the ground truth for whether the agent is alive and the clip-changed listener is firing.
 */
export default function LogsScreen() {
  // Newest-first: index 0 is the latest line, so the list reads top-down with no per-render
  // reverse and no forced scroll — maintainVisibleContentPosition keeps the reader in place.
  const [lines, setLines] = useState<LogLine[]>([]);
  const [daemonLog, setDaemonLog] = useState<string | null>(null);
  const [fetching, setFetching] = useState(false);
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
    const clip = SelfAdb.addListener('onClip', (e) =>
      append(`${clock()}  clip ⬆ "${preview(e.text, 50)}"`),
    );
    return () => {
      log.remove();
      status.remove();
      relay.remove();
      clip.remove();
    };
  }, [append]);

  const fetchDaemonLog = useCallback(() => {
    setFetching(true);
    setDaemonLog(null);
    SelfAdb.readDaemonLog()
      .then(setDaemonLog)
      .catch((e: any) => setDaemonLog(`Error: ${e?.message ?? String(e)}`))
      .finally(() => setFetching(false));
  }, []);

  const shareAll = useCallback(() => {
    const body = [
      '=== Application Logs ===',
      ...[...lines].reverse().map((l) => l.text), // chronological for sharing
      ...(daemonLog ? ['', '=== Device (daemon) Log ===', daemonLog] : []),
    ].join('\n');
    Share.share({ message: body }).catch(() => {});
  }, [lines, daemonLog]);

  const clear = useCallback(() => {
    SelfAdb.clearLogs().catch(() => {});
    setLines([]);
    setDaemonLog(null);
  }, []);

  return (
    <View className="flex-1 gap-4 bg-background p-4">
      <View className="flex-row gap-2">
        <ToolbarButton icon="phonelink" label="Device Log" onPress={fetchDaemonLog} busy={fetching} />
        <ToolbarButton icon="delete-outline" label="Clear" onPress={clear} destructive />
      </View>

      {daemonLog != null ? (
        <View className="gap-2 rounded-2xl bg-background-element p-4">
          <Text className="text-sm font-bold tracking-[0.5px] text-foreground-secondary">
            DEVICE (DAEMON) LOG
          </Text>
          <ScrollView className="max-h-55">
            <Text className="font-[monospace] text-[11px] font-medium leading-4 text-foreground">
              {daemonLog}
            </Text>
          </ScrollView>
        </View>
      ) : null}

      <FlatList
        data={lines}
        keyExtractor={(line) => String(line.id)}
        className="flex-1 rounded-2xl"
        contentContainerClassName="gap-0.5 p-4"
        // Pinned to the newest line while at the top; stable (no jump) while reading older lines.
        maintainVisibleContentPosition={{ minIndexForVisible: 0, autoscrollToTopThreshold: 16 }}
        renderItem={({ item }) => (
          <Text
            className={`font-[monospace] text-[11px] font-medium leading-4 ${lineClass(item.text)}`}>
            {item.text}
          </Text>
        )}
      />
    </View>
  );
}

/** Tint a few high-signal lines so failures stand out while scanning. */
function lineClass(line: string): string {
  const l = line.toLowerCase();
  if (l.includes('error') || l.includes('hata') || l.includes('fail') || l.includes('retry')) {
    return 'text-[#e5484d]';
  }
  if (l.includes('clip ⬆') || l.includes('-> clipboard') || l.includes('captured')) {
    return 'text-[#2ecc71]';
  }
  return 'text-foreground-secondary';
}

function ToolbarButton({
  icon,
  label,
  onPress,
  busy,
  destructive,
}: {
  icon: keyof typeof MaterialIcons.glyphMap;
  label: string;
  onPress: () => void;
  busy?: boolean;
  destructive?: boolean;
}) {
  const theme = useTheme();
  // MaterialIcons / ActivityIndicator take a `color` prop (not a style), so resolve it in JS.
  const color = destructive ? '#e5484d' : theme.text;
  return (
    <Pressable onPress={onPress} disabled={busy} className="flex-1 active:opacity-60">
      <View className="flex-row items-center justify-center gap-2 rounded-2xl bg-background-element py-4">
        {busy ? (
          <ActivityIndicator size="small" color={color} />
        ) : (
          <MaterialIcons name={icon} size={22} color={color} />
        )}
        <Text className={`text-sm font-medium ${destructive ? 'text-[#e5484d]' : 'text-foreground'}`}>
          {label}
        </Text>
      </View>
    </Pressable>
  );
}
