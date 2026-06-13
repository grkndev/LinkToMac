import {
  Box,
  Column,
  Host,
  HorizontalDivider,
  Icon,
  ListItem,
  Switch,
  Text,
  useMaterialColors,
  type MaterialColors,
} from '@expo/ui/jetpack-compose';
import {
  background,
  clickable,
  clip,
  fillMaxWidth,
  padding,
  Shapes,
  size,
  toggleable,
  verticalScroll,
} from '@expo/ui/jetpack-compose/modifiers';
import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Alert, AppState, StyleSheet, useColorScheme } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Spacing } from '@/constants/theme';
import { usePairing } from '@/features/relay/pairing-context';
import SelfAdb from '@/features/selfadb/client';

/** Brand blue (app.json notification color) — seeds the whole Material 3 palette. */
const SEED = '#208AEF';

/** Material XML vector drawables (see assets/icons), tinted by the `Icon` component. */
const ICONS = {
  notifications: require('../../assets/icons/notifications.xml'),
  notificationsActive: require('../../assets/icons/notifications_active.xml'),
  contentCopy: require('../../assets/icons/content_copy.xml'),
  battery: require('../../assets/icons/battery_charging_full.xml'),
  qr: require('../../assets/icons/qr_code_scanner.xml'),
  linkOff: require('../../assets/icons/link_off.xml'),
  terminal: require('../../assets/icons/terminal.xml'),
  chevron: require('../../assets/icons/chevron_right.xml'),
};

type Tone = 'primary' | 'secondary' | 'tertiary' | 'error';

/** Tonal container + on-container pair for an expressive icon bubble. */
function tonal(colors: MaterialColors, tone: Tone) {
  switch (tone) {
    case 'secondary':
      return { container: colors.secondaryContainer, on: colors.onSecondaryContainer };
    case 'tertiary':
      return { container: colors.tertiaryContainer, on: colors.onTertiaryContainer };
    case 'error':
      return { container: colors.errorContainer, on: colors.onErrorContainer };
    default:
      return { container: colors.primaryContainer, on: colors.onPrimaryContainer };
  }
}

export default function SettingsScreen() {
  const router = useRouter();
  const { paused, setPaused, unpair } = usePairing();
  const insets = useSafeAreaInsets();
  const scheme = useColorScheme();
  const colors = useMaterialColors({ seedColor: SEED });

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
    <Host style={{ flex: 1, backgroundColor: colors.background }} seedColor={SEED} colorScheme={scheme}>
      <Column
        modifiers={[
          fillMaxWidth(),
          verticalScroll(),
          padding(Spacing.three, Spacing.three, Spacing.three, insets.bottom + Spacing.five),
        ]}
        verticalArrangement={{ spacedBy: Spacing.four }}
      >
        <Section title="Bildirimler">
          <SwitchRow
            icon={ICONS.notifications}
            tone="primary"
            label="Bildirim simgesini göster"
            hint="Kapalıyken kalıcı bildirim durum çubuğunda simge göstermez."
            value={notifIconVisible}
            onValueChange={toggleNotifIcon}
          />
          {notifGranted === false ? (
            <>
              <RowDivider />
              <ActionRow
                icon={ICONS.notificationsActive}
                tone="tertiary"
                label="Bildirim izni ver"
                hint="İzin olmadan bağlantı durumu bildirimi gösterilemez."
                onPress={() => {
                  SelfAdb.requestPostNotifications().then(setNotifGranted).catch(() => {});
                }}
              />
            </>
          ) : null}
        </Section>

        <Section title="Senkronizasyon">
          <SwitchRow
            icon={ICONS.contentCopy}
            tone="secondary"
            label="Pano senkronizasyonu"
            hint="Kapalıyken panodaki kopyalar Mac’e iletilmez."
            value={!paused}
            onValueChange={(on) => setPaused(!on)}
          />
        </Section>

        <Section title="Sistem">
          {batteryOk === false ? (
            <ActionRow
              icon={ICONS.battery}
              tone="tertiary"
              label="Pil optimizasyonunu kapat"
              hint="Arka planda kesintisiz çalışmak için gerekli."
              onPress={() => {
                SelfAdb.requestIgnoreBatteryOptimizations().catch(() => {});
              }}
            />
          ) : (
            <InfoRow
              icon={ICONS.battery}
              tone="tertiary"
              label="Pil optimizasyonu"
              value={batteryOk ? 'Muaf' : '—'}
            />
          )}
        </Section>

        <Section title="Eşleştirme">
          <ActionRow
            icon={ICONS.qr}
            tone="primary"
            label="Yeniden eşleştir (QR tara)"
            hint="Mac’teki Pairing QR penceresini yeniden okut."
            onPress={() => router.push('/qr-scan')}
          />
          <RowDivider />
          <ActionRow
            icon={ICONS.linkOff}
            label="Eşi kaldır"
            destructive
            onPress={confirmUnpair}
          />
        </Section>

        <Section title="Geliştirici">
          <ActionRow
            icon={ICONS.terminal}
            tone="secondary"
            label="Günlükler"
            hint="ADB ve cihaz loglarını görüntüle (pano senkronu sorunlarını ayıklamak için)."
            onPress={() => router.push('/logs')}
          />
        </Section>
      </Column>
    </Host>
  );
}

/** Section header (primary, emphasized) + a tonal, extra-large rounded container. */
function Section({ title, children }: { title: string; children: React.ReactNode }) {
  const colors = useMaterialColors({ seedColor: SEED });
  return (
    <Column modifiers={[fillMaxWidth()]} verticalArrangement={{ spacedBy: Spacing.two }}>
      <Text
        modifiers={[padding(Spacing.three, 0, 0, 0)]}
        color={colors.primary}
        style={{ typography: 'titleSmall', fontWeight: '700' }}
      >
        {title}
      </Text>
      <Column
        modifiers={[
          fillMaxWidth(),
          clip(Shapes.RoundedCorner(28)),
          background(colors.surfaceContainerHigh),
        ]}
      >
        {children}
      </Column>
    </Column>
  );
}

/** The signature M3 Expressive leading element: an icon inside a tonal circle. */
function IconBubble({ source, tone }: { source: number; tone: Tone }) {
  const colors = useMaterialColors({ seedColor: SEED });
  const t = tonal(colors, tone);
  return (
    <Box
      contentAlignment="center"
      modifiers={[size(40, 40), clip(Shapes.Circle), background(t.container)]}
    >
      <Icon source={source} size={22} tint={t.on} />
    </Box>
  );
}

function SwitchRow({
  icon,
  tone,
  label,
  hint,
  value,
  onValueChange,
}: {
  icon: number;
  tone: Tone;
  label: string;
  hint?: string;
  value: boolean;
  onValueChange: (value: boolean) => void;
}) {
  const colors = useMaterialColors({ seedColor: SEED });
  return (
    <ListItem
      colors={{ containerColor: 'transparent' }}
      modifiers={[
        fillMaxWidth(),
        toggleable(value, () => onValueChange(!value), { role: 'switch' }),
      ]}
    >
      <ListItem.LeadingContent>
        <IconBubble source={icon} tone={tone} />
      </ListItem.LeadingContent>
      <ListItem.HeadlineContent>
        <Text color={colors.onSurface} style={{ typography: 'bodyLarge', fontWeight: '500' }}>
          {label}
        </Text>
      </ListItem.HeadlineContent>
      {hint ? (
        <ListItem.SupportingContent>
          <Text color={colors.onSurfaceVariant} style={{ typography: 'bodyMedium' }}>
            {hint}
          </Text>
        </ListItem.SupportingContent>
      ) : null}
      <ListItem.TrailingContent>
        <Switch value={value} />
      </ListItem.TrailingContent>
    </ListItem>
  );
}

function ActionRow({
  icon,
  tone = 'primary',
  label,
  hint,
  destructive,
  onPress,
}: {
  icon: number;
  tone?: Tone;
  label: string;
  hint?: string;
  destructive?: boolean;
  onPress: () => void;
}) {
  const colors = useMaterialColors({ seedColor: SEED });
  return (
    <ListItem
      colors={{ containerColor: 'transparent' }}
      modifiers={[fillMaxWidth(), clickable(onPress)]}
    >
      <ListItem.LeadingContent>
        <IconBubble source={icon} tone={destructive ? 'error' : tone} />
      </ListItem.LeadingContent>
      <ListItem.HeadlineContent>
        <Text
          color={destructive ? colors.error : colors.onSurface}
          style={{ typography: 'bodyLarge', fontWeight: '500' }}
        >
          {label}
        </Text>
      </ListItem.HeadlineContent>
      {hint ? (
        <ListItem.SupportingContent>
          <Text color={colors.onSurfaceVariant} style={{ typography: 'bodyMedium' }}>
            {hint}
          </Text>
        </ListItem.SupportingContent>
      ) : null}
      <ListItem.TrailingContent>
        <Icon
          source={ICONS.chevron}
          size={22}
          tint={destructive ? colors.error : colors.onSurfaceVariant}
        />
      </ListItem.TrailingContent>
    </ListItem>
  );
}

function InfoRow({
  icon,
  tone,
  label,
  value,
}: {
  icon: number;
  tone: Tone;
  label: string;
  value: string;
}) {
  const colors = useMaterialColors({ seedColor: SEED });
  return (
    <ListItem colors={{ containerColor: 'transparent' }} modifiers={[fillMaxWidth()]}>
      <ListItem.LeadingContent>
        <IconBubble source={icon} tone={tone} />
      </ListItem.LeadingContent>
      <ListItem.HeadlineContent>
        <Text color={colors.onSurface} style={{ typography: 'bodyLarge', fontWeight: '500' }}>
          {label}
        </Text>
      </ListItem.HeadlineContent>
      <ListItem.TrailingContent>
        <Text color={colors.onSurfaceVariant} style={{ typography: 'labelLarge', fontWeight: '600' }}>
          {value}
        </Text>
      </ListItem.TrailingContent>
    </ListItem>
  );
}

/** Hairline divider inset to align under the row's headline (bubble + gutters ≈ 72dp). */
function RowDivider() {
  const colors = useMaterialColors({ seedColor: SEED });
  return (
    <HorizontalDivider
      thickness={StyleSheet.hairlineWidth}
      color={colors.outlineVariant}
      modifiers={[padding(72, 0, Spacing.three, 0)]}
    />
  );
}
