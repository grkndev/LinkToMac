import { MaterialIcons } from '@expo/vector-icons';
import { useRouter } from 'expo-router';
import { Alert, Pressable, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';
import { usePairing } from '@/features/relay/pairing-context';
import { useRelayStatus } from '@/features/relay/use-relay-status';
import { useTheme } from '@/hooks/use-theme';

const CONNECTED_COLOR = '#2ecc71';
const DISCONNECTED_COLOR = '#e5484d';

/** Home: paired Mac's identity + connection state, plus quick actions. */
export default function HomeScreen() {
  const theme = useTheme();
  const router = useRouter();
  const { pairing, paused } = usePairing();
  const { relay, lastClip } = useRelayStatus();

  const connected = relay.peerOnline && !paused;
  const statusLabel = paused ? 'Duraklatıldı' : connected ? 'Bağlı' : 'Bağlı değil';

  return (
    <ThemedView style={styles.root}>
      <SafeAreaView style={styles.safe}>
        <View style={styles.topBar}>
          <Pressable onPress={() => router.push('/settings')} hitSlop={Spacing.two}>
            <MaterialIcons name="settings" size={26} color={theme.textSecondary} />
          </Pressable>
        </View>

        <View style={styles.hero}>
          <ThemedView type="backgroundElement" style={styles.deviceBadge}>
            <MaterialIcons name="laptop-mac" size={48} color={theme.textSecondary} />
          </ThemedView>
          <ThemedText type="title" style={{ textAlign: 'center' }}>
            {pairing?.name ?? 'Mac'}
          </ThemedText>
          <View style={styles.statusRow}>
            <View
              style={[
                styles.statusDot,
                { backgroundColor: connected ? CONNECTED_COLOR : DISCONNECTED_COLOR },
              ]}
            />
            <ThemedText type="small" themeColor="textSecondary">
              {statusLabel}
            </ThemedText>
          </View>
        </View>

        <View style={styles.actions}>
          <ActionButton icon="lock-outline" label="PC'yi Kilitle" />
          <ActionButton icon="send" label="Dosya Gönder" />
          <ActionButton icon="cast" label="Ekranı Yansıt" />
        </View>

        <View style={styles.list}>
          <ListRow icon="folder-open" label="Alınan dosyalar" value="Yakında" />
          <ListRow
            icon="content-paste"
            label="Pano"
            value={lastClip ? truncate(lastClip) : 'Henüz kopyalanan bir şey yok'}
          />
        </View>
      </SafeAreaView>
    </ThemedView>
  );
}

/** Placeholder quick action; functionality lands in a later update. */
function ActionButton({
  icon,
  label,
}: {
  icon: keyof typeof MaterialIcons.glyphMap;
  label: string;
}) {
  const theme = useTheme();
  return (
    <Pressable
      style={styles.action}
      onPress={() => Alert.alert('Yakında', 'Bu özellik henüz hazır değil.')}>
      <ThemedView type="backgroundElement" style={styles.actionIcon}>
        <MaterialIcons name={icon} size={26} color={theme.textSecondary} />
      </ThemedView>
      <ThemedText type="small" themeColor="textSecondary" style={styles.actionLabel}>
        {label}
      </ThemedText>
    </Pressable>
  );
}

function ListRow({
  icon,
  label,
  value,
}: {
  icon: keyof typeof MaterialIcons.glyphMap;
  label: string;
  value: string;
}) {
  const theme = useTheme();
  return (
    <ThemedView type="backgroundElement" style={styles.row}>
      <MaterialIcons name={icon} size={22} color={theme.textSecondary} />
      <View style={styles.rowText}>
        <ThemedText type="smallBold">{label}</ThemedText>
        <ThemedText type="small" themeColor="textSecondary" numberOfLines={1}>
          {value}
        </ThemedText>
      </View>
    </ThemedView>
  );
}

function truncate(s: string): string {
  return s.length > 40 ? `${s.slice(0, 40)}…` : s;
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  safe: { flex: 1, padding: Spacing.four, gap: Spacing.five },
  topBar: { flexDirection: 'row', justifyContent: 'flex-end' },
  hero: { alignItems: 'center', gap: Spacing.two },
  deviceBadge: {
    width: 96,
    height: 96,
    borderRadius: Spacing.three,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: Spacing.two,
  },
  statusRow: { flexDirection: 'row', alignItems: 'center', gap: Spacing.two },
  statusDot: { width: 8, height: 8, borderRadius: 4 },
  actions: { flexDirection: 'row', gap: Spacing.three },
  action: { flex: 1, alignItems: 'center', gap: Spacing.two, opacity: 0.4 },
  actionIcon: {
    alignSelf: 'stretch',
    borderRadius: Spacing.three,
    paddingVertical: Spacing.three,
    alignItems: 'center',
    justifyContent: 'center',
  },
  actionLabel: { textAlign: 'center' },
  list: { gap: Spacing.three },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.three,
    borderRadius: Spacing.three,
    padding: Spacing.three,
  },
  rowText: { flex: 1, gap: Spacing.half },
});
