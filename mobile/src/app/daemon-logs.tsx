import { MaterialIcons } from '@expo/vector-icons';
import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, FlatList, Pressable, Share, Text, View } from 'react-native';

import SelfAdb, { CLIP_PORT } from '@/features/selfadb/client';
import { useTheme } from '@/hooks/use-theme';

/**
 * The privileged clipboard daemon's OWN on-device log — the ground truth for whether the shell
 * agent is alive, its system context built, and the clip-changed listener is capturing.
 *
 * Read over the localhost bridge (no adb, so it can't hit libadb's BufferOverflowException); the
 * daemon stamps each line with its own HH:mm:ss when it writes it (the whole buffer is fetched at
 * once, so the app can't time individual lines). "Restart" reloads a rebuilt dex without a reboot.
 */
export default function DaemonLogsScreen() {
  const [text, setText] = useState<string | null>(null);
  const [fetching, setFetching] = useState(false);
  const [restarting, setRestarting] = useState(false);

  const fetchLog = useCallback(() => {
    setFetching(true);
    SelfAdb.readDaemonLog()
      .then(setText)
      .catch((e: any) => setText(`Error: ${e?.message ?? String(e)}`))
      .finally(() => setFetching(false));
  }, []);

  // Pull once on open (state is only set from the async callbacks, never synchronously here).
  useEffect(() => {
    let alive = true;
    SelfAdb.readDaemonLog()
      .then((blob) => alive && setText(blob))
      .catch((e: any) => alive && setText(`Error: ${e?.message ?? String(e)}`));
    return () => {
      alive = false;
    };
  }, []);

  const restartDaemon = useCallback(() => {
    setRestarting(true);
    SelfAdb.restartDaemon(CLIP_PORT)
      .then((msg) => setText(`${msg}\n\n(Tap Refresh to pull the new daemon log.)`))
      .catch((e: any) => setText(`Restart error: ${e?.message ?? String(e)}`))
      .finally(() => setRestarting(false));
  }, []);

  const shareAll = useCallback(() => {
    Share.share({ message: text ?? '' }).catch(() => {});
  }, [text]);

  const lines = (text ?? '').split('\n');

  return (
    <View className="flex-1 gap-4 bg-background p-4">
      <View className="flex-row gap-2">
        <ToolbarButton icon="refresh" label="Refresh" onPress={fetchLog} busy={fetching} />
        <ToolbarButton icon="restart-alt" label="Restart" onPress={restartDaemon} busy={restarting} />
        <ToolbarButton icon="share" label="Share" onPress={shareAll} />
      </View>

      <FlatList
        data={lines}
        keyExtractor={(_, i) => String(i)}
        className="flex-1 rounded-2xl bg-background-element"
        contentContainerClassName="gap-0.5 p-4"
        renderItem={({ item }) => (
          <Text
            className={`font-[monospace] text-[11px] font-medium leading-4 ${lineClass(item)}`}>
            {item || ' '}
          </Text>
        )}
        ListEmptyComponent={
          <Text className="font-[monospace] text-[11px] text-foreground-secondary">
            {fetching ? 'Fetching daemon log…' : 'No daemon log.'}
          </Text>
        }
      />
    </View>
  );
}

/** Tint high-signal lines so failures/successes stand out while scanning. */
function lineClass(line: string): string {
  const l = line.toLowerCase();
  if (l.includes('error') || l.includes('hata') || l.includes('fail') || l.includes('exception')) {
    return 'text-[#e5484d]';
  }
  if (l.includes('captured') || l.includes('context ready') || l.includes('-> emit') || l.includes('-> mac')) {
    return 'text-[#2ecc71]';
  }
  return 'text-foreground-secondary';
}

function ToolbarButton({
  icon,
  label,
  onPress,
  busy,
}: {
  icon: keyof typeof MaterialIcons.glyphMap;
  label: string;
  onPress: () => void;
  busy?: boolean;
}) {
  const theme = useTheme();
  return (
    <Pressable onPress={onPress} disabled={busy} className="flex-1 active:opacity-60">
      <View className="flex-row items-center justify-center gap-2 rounded-2xl bg-background-element py-4">
        {busy ? (
          <ActivityIndicator size="small" color={theme.text} />
        ) : (
          <MaterialIcons name={icon} size={22} color={theme.text} />
        )}
        <Text className="text-sm font-medium text-foreground">{label}</Text>
      </View>
    </Pressable>
  );
}
