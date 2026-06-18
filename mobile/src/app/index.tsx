import {
  Box,
  Column,
  Host,
  Icon,
  ListItem,
  Row,
  Shape,
  Surface,
  Text,
  type MaterialColors,
} from '@expo/ui/jetpack-compose';
import {
  alpha,
  background,
  clip,
  fillMaxSize,
  fillMaxWidth,
  padding,
  Shapes,
  size,
  verticalScroll,
  weight,
} from '@expo/ui/jetpack-compose/modifiers';
import * as Haptics from 'expo-haptics';
import { useRouter } from 'expo-router';
import { Alert, useColorScheme } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import {
  ButtonGroup,
  Group,
  IconCircle,
  SEED,
  groupShape,
  groupShapeH,
  tonal,
  useM3Colors,
  type RowShape,
} from '@/components/m3';
import { useIcons, type IconSource } from '@/components/icons';
import { Spacing } from '@/constants/theme';
import SelfAdb from '@/features/selfadb/client';
import { useClipHistory } from '@/features/clip-history/use-clip-history';
import { usePairing } from '@/features/relay/pairing-context';
import { useRelayStatus } from '@/features/relay/use-relay-status';

/** Brand green for the "online" status dot — M3 has no green role, so this stays a literal. */
const ONLINE = '#2ECC71';
/** Amber for the transient connecting/reconnecting state (M3 has no amber role). */
const RECONNECTING = '#F39C12';
/** How many failed reconnect attempts before the UI gives up and shows "Disconnected".
 *  The link keeps retrying in the background regardless; this is purely the label threshold. */
const RECONNECT_LIMIT = 3;

/** 28dp "extra-large" rounded square for the expressive hero tile. */
const HERO_SHAPE = Shape.RoundedCorner({
  cornerRadii: { topStart: 28, topEnd: 28, bottomStart: 28, bottomEnd: 28 },
});

/** Pill for the LAN/Relay transport chip next to the connection status. */
const CHIP_SHAPE = Shape.RoundedCorner({
  cornerRadii: { topStart: 8, topEnd: 8, bottomStart: 8, bottomEnd: 8 },
});

/** Home: paired Mac's identity + connection state, plus quick actions. */
export default function HomeScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const scheme = useColorScheme();
  const colors = useM3Colors();
  const icons = useIcons();
  const { pairing } = usePairing();
  const { relay } = useRelayStatus();
  const { items: clipItems } = useClipHistory();

  const connected = relay.peerOnline;
  // The link auto-reconnects with backoff; show "Reconnecting" while it's actively retrying, and
  // only fall back to "Disconnected" once it's tried RECONNECT_LIMIT times (or hit a dead end).
  const retrying = !connected && (relay.status === 'connecting' || relay.status === 'connected');
  const attempt = relay.attempt ?? 0;
  const connState: 'connected' | 'connecting' | 'reconnecting' | 'disconnected' = connected
    ? 'connected'
    : retrying && attempt < RECONNECT_LIMIT
      ? attempt === 0
        ? 'connecting'
        : 'reconnecting'
      : 'disconnected';
  const statusLabel =
    connState === 'connected'
      ? 'Connected'
      : connState === 'connecting'
        ? 'Connecting…'
        : connState === 'reconnecting'
          ? 'Reconnecting…'
          : 'Disconnected';
  const statusColor =
    connState === 'connected' ? ONLINE : connState === 'disconnected' ? colors.error : RECONNECTING;
  // How the link is carried: direct over the LAN, or via the relay. Only meaningful while connected.
  const transportLabel =
    relay.transport === 'lan' ? 'LAN' : relay.transport === 'relay' ? 'Relay' : null;

  const latestMacClip = clipItems?.[0]?.text;
  const clipValue = latestMacClip
    ? truncate(latestMacClip)
    : clipItems === null
      ? ''
      : 'No items received yet';

  return (
    <Host style={{ flex: 1, backgroundColor: colors.background }} seedColor={SEED} colorScheme={scheme}>
      <Column
        modifiers={[
          fillMaxWidth(),
          verticalScroll(),
          padding(
            Spacing.three,
            insets.top + Spacing.two,
            Spacing.three,
            insets.bottom + Spacing.five,
          ),
        ]}
        verticalArrangement={{ spacedBy: Spacing.five }}
      >
        {/* Top bar: settings entry point. */}
        <Row modifiers={[fillMaxWidth()]} horizontalArrangement="end">
          <Surface
            color={colors.surfaceContainerHigh}
            shape={HERO_SHAPE}
            onClick={() => router.push('/settings')}
            modifiers={[size(44, 44)]}
          >
            <Box contentAlignment="center" modifiers={[fillMaxSize()]}>
              <Icon source={icons.settings} size={24} tint={colors.onSurfaceVariant} />
            </Box>
          </Surface>
        </Row>

        {/* Hero: the paired Mac's identity + live connection status. */}
        <Column
          modifiers={[fillMaxWidth()]}
          horizontalAlignment="center"
          verticalArrangement={{ spacedBy: Spacing.two }}
        >
          <Surface color={colors.secondaryContainer} shape={HERO_SHAPE} modifiers={[size(96, 96)]}>
            <Box contentAlignment="center" modifiers={[fillMaxSize()]}>
              <Icon source={icons.laptop} size={46} tint={colors.onSecondaryContainer} />
            </Box>
          </Surface>
          <Text
            color={colors.onSurface}
            style={{ typography: 'headlineLarge', fontWeight: '600', textAlign: 'center' }}
          >
            {pairing?.name ?? 'Mac'}
          </Text>
          <Row verticalAlignment="center" horizontalArrangement={{ spacedBy: Spacing.two }}>
            <Box
              modifiers={[size(8, 8), clip(Shapes.Circle), background(statusColor)]}
            />
            <Text
              color={colors.onSurfaceVariant}
              style={{ typography: 'labelLarge', fontWeight: '600' }}
            >
              {statusLabel}
            </Text>
            {connected && transportLabel ? (
              <Surface color={colors.secondaryContainer} shape={CHIP_SHAPE}>
                <Box modifiers={[padding(Spacing.two, Spacing.one, Spacing.two, Spacing.one)]}>
                  <Text
                    color={colors.onSecondaryContainer}
                    style={{ typography: 'labelMedium', fontWeight: '700' }}
                  >
                    {transportLabel}
                  </Text>
                </Box>
              </Surface>
            ) : null}
          </Row>
        </Column>

        {/* Quick actions — Lock Mac is live (needs a connected Mac); Cast is still a placeholder. */}
        <ButtonGroup>
          <ActionTile
            colors={colors}
            icon={icons.lock}
            label="Lock Mac"
            enabled={connected}
            onPress={() => {
              Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium).catch(() => {});
              SelfAdb.sendCommand('lock').catch(() => {});
            }}
          />
          <ActionTile colors={colors} icon={icons.cast} label="Cast Screen" />
        </ButtonGroup>

        {/* Info list — same grouped-list language as Settings. */}
        <Group>
          <InfoRow colors={colors} icon={icons.folder} label="Received files" value="Soon" />
          <InfoRow
            colors={colors}
            icon={icons.clipboard}
            label="Clipboard"
            value={clipValue}
            onClick={() => router.push('/clipboard-history')}
          />
        </Group>
      </Column>
    </Host>
  );
}

/**
 * Equal-width quick action. Live when given an `onPress` and `enabled`; otherwise dimmed —
 * either a placeholder (no `onPress` → "Soon") or an action that needs a connected Mac
 * (`enabled={false}` → "Not connected").
 */
function ActionTile({
  colors,
  icon,
  label,
  onPress,
  enabled = true,
  shape = groupShapeH(true, true),
}: {
  colors: MaterialColors;
  icon: IconSource;
  label: string;
  onPress?: () => void;
  enabled?: boolean;
  shape?: RowShape;
}) {
  const t = tonal(colors, 'secondary');
  const active = onPress != null && enabled;
  const handleClick = active
    ? onPress
    : onPress != null
      ? () => Alert.alert('Not connected', 'Connect to your Mac first.')
      : () => Alert.alert('Soon', 'This feature is not available yet.');
  return (
    <Surface
      color={colors.surfaceContainerHigh}
      shape={shape}
      onClick={handleClick}
      modifiers={active ? [weight(1)] : [weight(1), alpha(0.5)]}
    >
      <Column
        modifiers={[fillMaxWidth(), padding(Spacing.two, Spacing.three, Spacing.two, Spacing.three)]}
        horizontalAlignment="center"
        verticalArrangement={{ spacedBy: Spacing.two }}
      >
        <IconCircle source={icon} container={t.container} on={t.on} />
        <Text
          color={colors.onSurface}
          style={{ typography: 'labelLarge', fontWeight: '600', textAlign: 'center' }}
        >
          {label}
        </Text>
      </Column>
    </Surface>
  );
}

/** Rounded tonal row with a leading icon circle, a label, and a supporting value line. */
function InfoRow({
  colors,
  icon,
  label,
  value,
  onClick,
  shape = groupShape(true, true),
}: {
  colors: MaterialColors;
  icon: IconSource;
  label: string;
  value: string;
  onClick?: () => void;
  shape?: RowShape;
}) {
  const t = tonal(colors, 'secondary');
  return (
    <Surface color={colors.surfaceContainerHigh} shape={shape} modifiers={[fillMaxWidth()]} onClick={onClick}>
      <ListItem colors={{ containerColor: 'transparent' }} modifiers={[fillMaxWidth()]}>
        <ListItem.LeadingContent>
          <IconCircle source={icon} container={t.container} on={t.on} />
        </ListItem.LeadingContent>
        <ListItem.HeadlineContent>
          <Text color={colors.onSurface} style={{ typography: 'bodyLarge', fontWeight: '500' }}>
            {label}
          </Text>
        </ListItem.HeadlineContent>
        <ListItem.SupportingContent>
          <Text color={colors.onSurfaceVariant} style={{ typography: 'bodyMedium' }}>
            {value}
          </Text>
        </ListItem.SupportingContent>
      </ListItem>
    </Surface>
  );
}

function truncate(s: string): string {
  return s.length > 40 ? `${s.slice(0, 40)}…` : s;
}
