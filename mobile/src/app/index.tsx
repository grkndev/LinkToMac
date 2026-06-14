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
import { usePairing } from '@/features/relay/pairing-context';
import { useRelayStatus } from '@/features/relay/use-relay-status';

/** Brand green for the "online" status dot — M3 has no green role, so this stays a literal. */
const ONLINE = '#2ECC71';

/** 28dp "extra-large" rounded square for the expressive hero tile. */
const HERO_SHAPE = Shape.RoundedCorner({
  cornerRadii: { topStart: 28, topEnd: 28, bottomStart: 28, bottomEnd: 28 },
});

/** Home: paired Mac's identity + connection state, plus quick actions. */
export default function HomeScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const scheme = useColorScheme();
  const colors = useM3Colors();
  const icons = useIcons();
  const { pairing, paused } = usePairing();
  const { relay, lastClip } = useRelayStatus();

  const connected = relay.peerOnline && !paused;
  const statusLabel = paused ? 'Paused' : connected ? 'Connected' : 'Not connected';

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
              modifiers={[size(8, 8), clip(Shapes.Circle), background(connected ? ONLINE : colors.error)]}
            />
            <Text
              color={colors.onSurfaceVariant}
              style={{ typography: 'labelLarge', fontWeight: '600' }}
            >
              {statusLabel}
            </Text>
          </Row>
        </Column>

        {/* Quick actions — connected button group; placeholders, so dimmed + "coming soon". */}
        <ButtonGroup>
          <ActionTile colors={colors} icon={icons.lock} label="Lock Mac" />
          <ActionTile colors={colors} icon={icons.cast} label="Cast Screen" />
        </ButtonGroup>

        {/* Info list — same grouped-list language as Settings. */}
        <Group>
          <InfoRow colors={colors} icon={icons.folder} label="Received files" value="Soon" />
          <InfoRow
            colors={colors}
            icon={icons.clipboard}
            label="Clipboard"
            value={lastClip ? truncate(lastClip) : 'No items copied yet'}
          />
        </Group>
      </Column>
    </Host>
  );
}

/** Equal-width quick action; functionality lands in a later update, so it's dimmed. */
function 
ActionTile({
  colors,
  icon,
  label,
  shape = groupShapeH(true, true),
}: {
  colors: MaterialColors;
  icon: IconSource;
  label: string;
  shape?: RowShape;
}) {
  const t = tonal(colors, 'secondary');
  return (
    <Surface
      color={colors.surfaceContainerHigh}
      shape={shape}
      onClick={() => Alert.alert('Soon', 'This feature is not available yet.')}
      modifiers={[weight(1), alpha(0.5)]}
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
  shape = groupShape(true, true),
}: {
  colors: MaterialColors;
  icon: IconSource;
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
