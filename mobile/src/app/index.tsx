import { MaterialIcons } from '@expo/vector-icons';
import { useRouter } from 'expo-router';
import { Alert, Pressable, Text, View } from 'react-native';
import { SafeAreaView as RNSafeAreaView } from 'react-native-safe-area-context';
import { withUniwind } from 'uniwind';

import { usePairing } from '@/features/relay/pairing-context';
import { useRelayStatus } from '@/features/relay/use-relay-status';
import { useTheme } from '@/hooks/use-theme';

// SafeAreaView is third-party (not a core RN component), so it needs withUniwind
// to accept `className`. Wrap once at module level — never inside a render.
const SafeAreaView = withUniwind(RNSafeAreaView);

/** Home: paired Mac's identity + connection state, plus quick actions. */
export default function HomeScreen() {
  const theme = useTheme();
  const router = useRouter();
  const { pairing, paused } = usePairing();
  const { relay, lastClip } = useRelayStatus();

  const connected = relay.peerOnline && !paused;
  const statusLabel = paused ? 'Duraklatıldı' : connected ? 'Bağlı' : 'Bağlı değil';

  return (
    <View className="flex-1 bg-background">
      <SafeAreaView className="flex-1 gap-8 p-6">
        <View className="flex-row justify-end">
          <Pressable onPress={() => router.push('/settings')} hitSlop={8}>
            <MaterialIcons name="settings" size={26} color={theme.textSecondary} />
          </Pressable>
        </View>

        <View className="items-center gap-2">
          <View className="mb-2 h-24 w-24 items-center justify-center rounded-2xl bg-background-element">
            <MaterialIcons name="laptop-mac" size={48} color={theme.textSecondary} />
          </View>
          <Text className="text-center text-5xl font-semibold leading-13 text-foreground">
            {pairing?.name ?? 'Mac'}
          </Text>
          <View className="flex-row items-center gap-2">
            <View
              className={`h-2 w-2 rounded-full ${connected ? 'bg-[#2ecc71]' : 'bg-[#e5484d]'}`}
            />
            <Text className="text-sm font-medium text-foreground-secondary">{statusLabel}</Text>
          </View>
        </View>

        <View className="flex-row gap-4">
          <ActionButton icon="lock-outline" label="PC'yi Kilitle" />
          <ActionButton icon="send" label="Dosya Gönder" />
          <ActionButton icon="cast" label="Ekranı Yansıt" />
        </View>

        <View className="gap-4">
          <ListRow icon="folder-open" label="Alınan dosyalar" value="Yakında" />
          <ListRow
            icon="content-paste"
            label="Pano"
            value={lastClip ? truncate(lastClip) : 'Henüz kopyalanan bir şey yok'}
          />
        </View>
      </SafeAreaView>
    </View>
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
      className="flex-1 items-center gap-2 opacity-40"
      onPress={() => Alert.alert('Yakında', 'Bu özellik henüz hazır değil.')}>
      <View className="items-center justify-center self-stretch rounded-2xl bg-background-element py-4">
        <MaterialIcons name={icon} size={26} color={theme.textSecondary} />
      </View>
      <Text className="text-center text-sm font-medium text-foreground-secondary">{label}</Text>
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
    <View className="flex-row items-center gap-4 rounded-2xl bg-background-element p-4">
      <MaterialIcons name={icon} size={22} color={theme.textSecondary} />
      <View className="flex-1 gap-0.5">
        <Text className="text-sm font-bold text-foreground">{label}</Text>
        <Text className="text-sm font-medium text-foreground-secondary" numberOfLines={1}>
          {value}
        </Text>
      </View>
    </View>
  );
}

function truncate(s: string): string {
  return s.length > 40 ? `${s.slice(0, 40)}…` : s;
}
