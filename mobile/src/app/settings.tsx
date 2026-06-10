import { MaterialIcons } from '@expo/vector-icons';
import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Alert, AppState, Pressable, StyleSheet, Switch, View } from 'react-native';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';
import { usePairing } from '@/features/relay/pairing-context';
import SelfAdb from '@/features/selfadb/client';
import { useTheme } from '@/hooks/use-theme';

const DESTRUCTIVE_COLOR = '#e5484d';

export default function SettingsScreen() {
  const router = useRouter();
  const { paused, setPaused, unpair } = usePairing();

  const [notifIconVisible, setNotifIconVisible] = useState(true);
  const [notifGranted, setNotifGranted] = useState<boolean | null>(null);
  const [batteryOk, setBatteryOk] = useState<boolean | null>(null);

  useEffect(() => {
    SelfAdb.getStatusNotificationVisible().then(setNotifIconVisible).catch(() => {});
    SelfAdb.hasPostNotifications().then(setNotifGranted).catch(() => setNotifGranted(null));
    SelfAdb.hasIgnoreBatteryOptimizations().then(setBatteryOk).catch(() => setBatteryOk(null));

    // The battery exemption is granted in a system dialog/settings screen; re-check on return.
    const sub = AppState.addEventListener('change', (next) => {
      if (next !== 'active') return;
      SelfAdb.hasIgnoreBatteryOptimizations().then(setBatteryOk).catch(() => {});
      SelfAdb.hasPostNotifications().then(setNotifGranted).catch(() => {});
    });
    return () => sub.remove();
  }, []);

  const toggleNotifIcon = (visible: boolean) => {
    setNotifIconVisible(visible);
    SelfAdb.setStatusNotificationVisible(visible).catch(() => {});
  };

  const confirmUnpair = () => {
    Alert.alert(
      'Eşi kaldır',
      'Eşleştirme silinecek ve Mac bağlantısı kesilecek. Yeniden bağlanmak için Mac’teki QR’ı tekrar okutman gerekir.',
      [
        { text: 'Vazgeç', style: 'cancel' },
        { text: 'Kaldır', style: 'destructive', onPress: () => unpair() },
      ],
    );
  };

  return (
    <ThemedView style={styles.root}>
      <Section title="Bildirimler">
        <SwitchRow
          label="Bildirim simgesini göster"
          hint="Kapalıyken kalıcı bildirim durum çubuğunda simge göstermez."
          value={notifIconVisible}
          onValueChange={toggleNotifIcon}
        />
        {notifGranted === false ? (
          <ActionRow
            label="Bildirim izni ver"
            hint="İzin olmadan bağlantı durumu bildirimi gösterilemez."
            onPress={() => {
              SelfAdb.requestPostNotifications().then(setNotifGranted).catch(() => {});
            }}
          />
        ) : null}
      </Section>

      <Section title="Senkronizasyon">
        <SwitchRow
          label="Pano senkronizasyonu"
          hint="Kapalıyken panodaki kopyalar Mac’e iletilmez."
          value={!paused}
          onValueChange={(on) => setPaused(!on)}
        />
      </Section>

      <Section title="Sistem">
        {batteryOk === false ? (
          <ActionRow
            label="Pil optimizasyonunu kapat"
            hint="Arka planda kesintisiz çalışmak için gerekli."
            onPress={() => {
              SelfAdb.requestIgnoreBatteryOptimizations().catch(() => {});
            }}
          />
        ) : (
          <InfoRow label="Pil optimizasyonu" value={batteryOk ? 'Muaf' : '—'} />
        )}
      </Section>

      <Section title="Eşleştirme">
        <ActionRow
          label="Yeniden eşleştir (QR tara)"
          hint="Mac’teki Pairing QR penceresini yeniden okut."
          onPress={() => router.push('/qr-scan')}
        />
        <ActionRow label="Eşi kaldır" destructive onPress={confirmUnpair} />
      </Section>
    </ThemedView>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <View style={styles.section}>
      <ThemedText type="smallBold" themeColor="textSecondary" style={styles.sectionTitle}>
        {title}
      </ThemedText>
      <ThemedView type="backgroundElement" style={styles.card}>
        {children}
      </ThemedView>
    </View>
  );
}

function SwitchRow({
  label,
  hint,
  value,
  onValueChange,
}: {
  label: string;
  hint?: string;
  value: boolean;
  onValueChange: (value: boolean) => void;
}) {
  return (
    <View style={styles.row}>
      <View style={styles.rowText}>
        <ThemedText type="default">{label}</ThemedText>
        {hint ? (
          <ThemedText type="small" themeColor="textSecondary">
            {hint}
          </ThemedText>
        ) : null}
      </View>
      <Switch value={value} onValueChange={onValueChange} />
    </View>
  );
}

function ActionRow({
  label,
  hint,
  destructive,
  onPress,
}: {
  label: string;
  hint?: string;
  destructive?: boolean;
  onPress: () => void;
}) {
  const theme = useTheme();
  return (
    <Pressable onPress={onPress} style={styles.row}>
      <View style={styles.rowText}>
        <ThemedText type="default" style={destructive ? { color: DESTRUCTIVE_COLOR } : undefined}>
          {label}
        </ThemedText>
        {hint ? (
          <ThemedText type="small" themeColor="textSecondary">
            {hint}
          </ThemedText>
        ) : null}
      </View>
      <MaterialIcons
        name="chevron-right"
        size={22}
        color={destructive ? DESTRUCTIVE_COLOR : theme.textSecondary}
      />
    </Pressable>
  );
}

function InfoRow({ label, value }: { label: string; value: string }) {
  return (
    <View style={styles.row}>
      <ThemedText type="default" style={styles.rowText}>
        {label}
      </ThemedText>
      <ThemedText type="small" themeColor="textSecondary">
        {value}
      </ThemedText>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, padding: Spacing.four, gap: Spacing.four },
  section: { gap: Spacing.two },
  sectionTitle: { paddingHorizontal: Spacing.two },
  card: {
    borderRadius: Spacing.three,
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.one,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.three,
    paddingVertical: Spacing.three,
  },
  rowText: { flex: 1, gap: Spacing.half },
});
