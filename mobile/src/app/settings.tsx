import {
  Box,
  Column,
  Host,
  Icon,
  ListItem,
  Shape,
  Surface,
  Switch,
  Text,
  useMaterialColors,
  type MaterialColors,
} from '@expo/ui/jetpack-compose';
import {
  background,
  clip,
  fillMaxWidth,
  padding,
  Shapes,
  size,
  verticalScroll,
} from '@expo/ui/jetpack-compose/modifiers';
import { useRouter } from 'expo-router';
import { Children, cloneElement, isValidElement, useEffect, useState } from 'react';
import { Alert, AppState, useColorScheme } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Spacing } from '@/constants/theme';
import { usePairing } from '@/features/relay/pairing-context';
import SelfAdb from '@/features/selfadb/client';

/** Brand blue (app.json notification color) — seeds the whole Material 3 palette. */
const SEED = '#208AEF';

/**
 * Google-style grouped list: the rows in a section read as one rounded block, packed with a
 * hairline GROUP_GAP between them. The group's outer corners are large (R_OUTER); the corners
 * that touch a neighbour are small (R_INNER). A lone row keeps large corners all the way round.
 */
const GROUP_GAP = 3;
const R_OUTER = 24;
const R_INNER = 6;

type RowShape = ReturnType<typeof Shape.RoundedCorner>;

/** Position-aware corner radii for a row inside its group. */
function groupShape(isFirst: boolean, isLast: boolean): RowShape {
  const top = isFirst ? R_OUTER : R_INNER;
  const bottom = isLast ? R_OUTER : R_INNER;
  return Shape.RoundedCorner({
    cornerRadii: { topStart: top, topEnd: top, bottomStart: bottom, bottomEnd: bottom },
  });
}

/** Material XML vector drawables (see assets/icons), tinted by the `Icon` component. */
const ICONS = {
  notifications: require('../../assets/icons/notifications.xml'),
  notificationsActive: require('../../assets/icons/notifications_active.xml'),
  contentCopy: require('../../assets/icons/content_copy.xml'),
  battery: require('../../assets/icons/battery_charging_full.xml'),
  qr: require('../../assets/icons/qr_code_scanner.xml'),
  linkOff: require('../../assets/icons/link_off.xml'),
  terminal: require('../../assets/icons/terminal.xml'),
};

type Tone = 'secondary' | 'error';

/** Tonal container + on-container pair for the expressive leading icon circle. */
function tonal(colors: MaterialColors, tone: Tone) {
  return tone === 'error'
    ? { container: colors.errorContainer, on: colors.onErrorContainer }
    : { container: colors.secondaryContainer, on: colors.onSecondaryContainer };
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
      'Remove Pairing',
      'The pairing will be removed and the connection to the Mac will be disconnected. You will need to scan the QR code from your Mac to pair again.',
      [
        { text: 'Cancel', style: 'cancel' },
        { text: 'Remove', style: 'destructive', onPress: () => unpair() },
      ],
    );
  };

  return (
    <Host style={{ flex: 1, backgroundColor: colors.background }} seedColor={SEED} colorScheme={scheme}>
      {/* One continuous Google-style grouped list — every row is a segment of a single rounded
          block (no section labels, no dividers). A plain Column (not LazyColumn) is required:
          it lives inside the outer verticalScroll() Column, which passes infinite height
          constraints that crash a LazyColumn. */}
      <Column
        modifiers={[
          fillMaxWidth(),
          verticalScroll(),
          padding(Spacing.three, Spacing.three, Spacing.three, insets.bottom + Spacing.five),
        ]}
      >
        <Group>
          <SwitchRow
            colors={colors}
            icon={ICONS.notifications}
            label="Show notification icon"
            hint="A notification icon will be displayed in the status bar."
            value={notifIconVisible}
            onValueChange={toggleNotifIcon}
          />
          {notifGranted === false ? (
            <ActionRow
              colors={colors}
              icon={ICONS.notificationsActive}
              label="Grant notification permission"
              hint="Without permission, connection status notifications cannot be displayed."
              onPress={() => {
                SelfAdb.requestPostNotifications().then(setNotifGranted).catch(() => {});
              }}
            />
          ) : null}
          <SwitchRow
            colors={colors}
            icon={ICONS.contentCopy}
            label="Clipboard sync"
            hint="Copies from the clipboard will be sent to the Mac."
            value={!paused}
            onValueChange={(on) => setPaused(!on)}
          />
          {batteryOk === false ? (
            <ActionRow
              colors={colors}
              icon={ICONS.battery}
              label="Disable battery optimization"
              hint="Required for uninterrupted background operation."
              onPress={() => {
                SelfAdb.requestIgnoreBatteryOptimizations().catch(() => {});
              }}
            />
          ) : (
            <InfoRow
              colors={colors}
              icon={ICONS.battery}
              label="Battery Optimization"
              value={batteryOk ? 'Disabled' : '—'}
            />
          )}
          <ActionRow
            colors={colors}
            icon={ICONS.qr}
            label="Re-pair (Scan QR)"
            hint="Scan the Pairing QR from your Mac."
            onPress={() => router.push('/qr-scan')}
          />
          <ActionRow
            colors={colors}
            icon={ICONS.linkOff}
            label="Remove Pairing"
            hint="Disconnect and remove the pairing."
            destructive
            onPress={confirmUnpair}
          />
          <ActionRow
            colors={colors}
            icon={ICONS.terminal}
            label="Logs"
            hint="View ADB and device logs."
            onPress={() => router.push('/logs')}
          />
        </Group>
      </Column>
    </Host>
  );
}

/** One continuous grouped list: clones each rendered row with position-aware corner radii. */
function Group({ children }: { children: React.ReactNode }) {
  // toArray drops the `null`s from conditionally-rendered rows, so first/last land correctly.
  const rows = Children.toArray(children);
  return (
    <Column modifiers={[fillMaxWidth()]} verticalArrangement={{ spacedBy: GROUP_GAP }}>
      {rows.map((row, i) =>
        isValidElement<{ shape?: RowShape }>(row)
          ? cloneElement(row, { shape: groupShape(i === 0, i === rows.length - 1) })
          : row,
      )}
    </Column>
  );
}

/** The signature M3 Expressive leading element: an icon inside a tonal circle. */
function IconCircle({ source, container, on }: { source: number; container: string; on: string }) {
  return (
    <Box
      contentAlignment="center"
      modifiers={[size(40, 40), clip(Shapes.Circle), background(container)]}
    >
      <Icon source={source} size={22} tint={on} />
    </Box>
  );
}

/** Rounded tonal card that toggles its switch when tapped anywhere on the row. */
function SwitchRow({
  colors,
  icon,
  label,
  hint,
  value,
  onValueChange,
  shape = groupShape(true, true),
}: {
  colors: MaterialColors;
  icon: number;
  label: string;
  hint?: string;
  value: boolean;
  onValueChange: (value: boolean) => void;
  shape?: RowShape;
}) {
  const t = tonal(colors, 'secondary');
  return (
    <Surface
      color={colors.surfaceContainerHigh}
      shape={shape}
      modifiers={[fillMaxWidth()]}
      checked={value}
      onCheckedChange={onValueChange}
    >
      <ListItem colors={{ containerColor: 'transparent' }} modifiers={[fillMaxWidth()]}>
        <ListItem.LeadingContent>
          <IconCircle source={icon} container={t.container} on={t.on} />
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
          <Switch value={value} onCheckedChange={onValueChange} />
        </ListItem.TrailingContent>
      </ListItem>
    </Surface>
  );
}

/** Rounded tonal card with a tappable ripple over the whole row. */
function ActionRow({
  colors,
  icon,
  label,
  hint,
  destructive,
  onPress,
  shape = groupShape(true, true),
}: {
  colors: MaterialColors;
  icon: number;
  label: string;
  hint?: string;
  destructive?: boolean;
  onPress: () => void;
  shape?: RowShape;
}) {
  const t = tonal(colors, destructive ? 'error' : 'secondary');
  const labelColor = destructive ? colors.error : colors.onSurface;
  return (
    <Surface
      color={colors.surfaceContainerHigh}
      shape={shape}
      modifiers={[fillMaxWidth()]}
      onClick={onPress}
    >
      <ListItem colors={{ containerColor: 'transparent' }} modifiers={[fillMaxWidth()]}>
        <ListItem.LeadingContent>
          <IconCircle source={icon} container={t.container} on={t.on} />
        </ListItem.LeadingContent>
        <ListItem.HeadlineContent>
          <Text color={labelColor} style={{ typography: 'bodyLarge', fontWeight: '500' }}>
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
      </ListItem>
    </Surface>
  );
}

/** Rounded tonal card showing a read-only value on the trailing edge. */
function InfoRow({
  colors,
  icon,
  label,
  value,
  shape = groupShape(true, true),
}: {
  colors: MaterialColors;
  icon: number;
  label: string;
  value: string;
  shape?: RowShape;
}) {
  const t = tonal(colors, 'secondary');
  return (
    <Surface color={colors.surfaceContainerHigh} shape={shape} modifiers={[fillMaxWidth()]}>
      <ListItem colors={{ containerColor: 'transparent' }} modifiers={[fillMaxWidth()]}>
        <ListItem.LeadingContent>
          <IconCircle source={icon} container={t.container} on={t.on} />
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
    </Surface>
  );
}
