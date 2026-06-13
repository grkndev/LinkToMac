import { MaterialIcons } from '@expo/vector-icons';
import { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, Share, Text, View } from 'react-native';

import SelfAdb from '@/features/selfadb/client';
import { useTheme } from '@/hooks/use-theme';

const MAX_LINES = 500;

function clock(): string {
  return new Date().toTimeString().slice(0, 8); // HH:mm:ss — matches the native buffer format
}

function preview(text: string): string {
  const oneLine = text.replace(/\s+/g, ' ').trim();
  return oneLine.length > 50 ? `${oneLine.slice(0, 50)}…` : oneLine;
}

/**
 * Debug console for the clipboard pipeline. Seeds from the native log ring buffer
 * (retained across the JS-runtime gap) and then appends live onLog/onStatus/onRelay/onClip
 * events. "Cihaz günlüğünü getir" pulls the privileged daemon's own on-device log over adb —
 * the ground truth for whether the agent is alive and the clip-changed listener is firing.
 */
export default function LogsScreen() {
  const [lines, setLines] = useState<string[]>([]);
  const [daemonLog, setDaemonLog] = useState<string | null>(null);
  const [fetching, setFetching] = useState(false);
  const scrollRef = useRef<ScrollView>(null);

  const append = useCallback((line: string) => {
    setLines((prev) => {
      const next = prev.length >= MAX_LINES ? prev.slice(prev.length - MAX_LINES + 1) : prev;
      return [...next, line];
    });
  }, []);

  useEffect(() => {
    SelfAdb.getLogs()
      .then((seed) => setLines(seed.length ? seed : ['(henüz log yok)']))
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
      append(`${clock()}  clip ⬆ "${preview(e.text)}"`),
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
      .catch((e: any) => setDaemonLog(`Hata: ${e?.message ?? String(e)}`))
      .finally(() => setFetching(false));
  }, []);

  const shareAll = useCallback(() => {
    const body = [
      '=== Uygulama logları ===',
      ...lines,
      ...(daemonLog ? ['', '=== Cihaz (daemon) logu ===', daemonLog] : []),
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
        <ToolbarButton icon="phonelink" label="Cihaz günlüğü" onPress={fetchDaemonLog} busy={fetching} />
        <ToolbarButton icon="share" label="Paylaş" onPress={shareAll} />
        <ToolbarButton icon="delete-outline" label="Temizle" onPress={clear} destructive />
      </View>

      {daemonLog != null ? (
        <View className="gap-2 rounded-2xl bg-background-element p-4">
          <Text className="text-sm font-bold tracking-[0.5px] text-foreground-secondary">
            CİHAZ (DAEMON) LOGU
          </Text>
          <ScrollView className="max-h-55">
            <Text className="font-[monospace] text-[11px] font-medium leading-4 text-foreground">
              {daemonLog}
            </Text>
          </ScrollView>
        </View>
      ) : null}

      <ScrollView
        ref={scrollRef}
        className="flex-1 rounded-2xl"
        contentContainerClassName="gap-0.5 p-4"
        onContentSizeChange={() => scrollRef.current?.scrollToEnd({ animated: false })}>
        {lines.map((line, i) => (
          <Text
            key={i}
            className={`font-[monospace] text-[11px] font-medium leading-4 ${lineClass(line)}`}>
            {line}
          </Text>
        ))}
      </ScrollView>
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
