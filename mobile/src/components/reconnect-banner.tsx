import { useEffect, useState } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { StatusColors } from '@/constants/theme';

/**
 * Non-blocking counterpart to the full-screen Reconnect gate (issue #29). Shown when the
 * privileged clipboard daemon can't be (re)deployed over ADB right now, but the FGS-owned
 * relay/LAN link is alive — so remote lock, battery telemetry, and notification/SMS mirroring
 * keep working and the app shouldn't be a dead end (the classic case: phone on Mobile Hotspot,
 * where Wireless Debugging can never come up while it's a Wi-Fi AP rather than a client).
 * Dismissible per appearance — `visible` flipping false->true (a fresh occurrence, e.g. the
 * daemon dying again later in the session) clears a prior dismissal.
 */
export function ReconnectBanner({ visible, onRetry }: { visible: boolean; onRetry: () => void }) {
  const [dismissed, setDismissed] = useState(false);

  useEffect(() => {
    if (visible) setDismissed(false);
  }, [visible]);

  if (!visible || dismissed) return null;

  return (
    <SafeAreaView edges={['top']} style={styles.safe}>
      <View style={styles.row}>
        <ThemedText type="small" style={styles.text}>
          Clipboard daemon offline — reconnect ADB when back on Wi-Fi
        </ThemedText>
        <Pressable onPress={onRetry} hitSlop={8} style={styles.action}>
          <ThemedText type="smallBold" style={styles.actionText}>
            Retry
          </ThemedText>
        </Pressable>
        <Pressable onPress={() => setDismissed(true)} hitSlop={8} style={styles.action}>
          <ThemedText type="smallBold" style={styles.actionText}>
            ✕
          </ThemedText>
        </Pressable>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: { backgroundColor: StatusColors.warn },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingVertical: 10,
    gap: 12,
  },
  text: { flex: 1, color: '#1a1300' },
  action: { paddingHorizontal: 4, paddingVertical: 2 },
  actionText: { color: '#1a1300' },
});
