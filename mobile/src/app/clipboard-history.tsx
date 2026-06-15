import {
  Box,
  Column,
  Host,
  Icon,
  ListItem,
  LoadingIndicator,
  Surface,
  Text,
  type MaterialColors,
} from '@expo/ui/jetpack-compose';
import { fillMaxSize, fillMaxWidth, padding, verticalScroll } from '@expo/ui/jetpack-compose/modifiers';
import { useNavigation } from 'expo-router';
import { useLayoutEffect } from 'react';
import { Alert, Pressable, Text as RNText, ToastAndroid, useColorScheme } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useIcons, type IconSource } from '@/components/icons';
import { Group, IconCircle, SEED, groupShape, tonal, useM3Colors, type RowShape } from '@/components/m3';
import { Spacing } from '@/constants/theme';
import { useClipHistory, type ClipItem } from '@/features/clip-history/use-clip-history';
import SelfAdb from '@/features/selfadb/client';

/** Clipboard items received from the paired Mac — newest first, tap any to copy it back. */
export default function ClipboardHistoryScreen() {
  const navigation = useNavigation();
  const insets = useSafeAreaInsets();
  const scheme = useColorScheme();
  const colors = useM3Colors();
  const icons = useIcons();
  const { items, clear } = useClipHistory();

  const hasItems = !!items && items.length > 0;

  // A "Clear" affordance in the native header, only while there's something to clear.
  useLayoutEffect(() => {
    navigation.setOptions({
      headerRight: hasItems
        ? () => (
            <Pressable
              hitSlop={8}
              onPress={() =>
                Alert.alert('Clear history', 'Remove all received clipboard items?', [
                  { text: 'Cancel', style: 'cancel' },
                  { text: 'Clear', style: 'destructive', onPress: clear },
                ])
              }
            >
              <RNText style={{ color: colors.primary, fontSize: 16, fontWeight: '600' }}>Clear</RNText>
            </Pressable>
          )
        : undefined,
    });
  }, [navigation, hasItems, clear, colors.primary]);

  const copyBack = (text: string) => {
    SelfAdb.writeClipboard(text)
      .catch(() => ToastAndroid.show("Couldn't copy — connection not ready", ToastAndroid.SHORT));
  };

  return (
    <Host style={{ flex: 1, backgroundColor: colors.background }} seedColor={SEED} colorScheme={scheme}>
      {items === null ? (
        <Centered>
          <LoadingIndicator color={colors.primary} />
        </Centered>
      ) : items.length === 0 ? (
        <Centered>
          <IconCircle
            source={icons.clipboard}
            container={colors.secondaryContainer}
            on={colors.onSecondaryContainer}
            diameter={72}
            iconSize={34}
          />
          <Text color={colors.onSurface} style={{ typography: 'titleMedium', fontWeight: '600', textAlign: 'center' }}>
            No clipboard items yet
          </Text>
          <Text color={colors.onSurfaceVariant} style={{ typography: 'bodyMedium', textAlign: 'center' }}>
            Items your Mac copies will show up here.
          </Text>
        </Centered>
      ) : (
        <Column
          modifiers={[
            fillMaxWidth(),
            verticalScroll(),
            padding(Spacing.three, Spacing.two, Spacing.three, insets.bottom + Spacing.five),
          ]}
        >
          {/* Bounded (≤100) grouped list — a plain Column, not LazyColumn, since it lives inside
              the outer verticalScroll() (infinite-height constraints crash a LazyColumn). */}
          <Group>
            {items.map((item, i) => (
              <ClipRow key={`${item.ts}-${i}`} colors={colors} icon={icons} item={item} onPress={() => copyBack(item.text)} />
            ))}
          </Group>
        </Column>
      )}
    </Host>
  );
}

/** Centered single-column layout for the loading + empty states. */
function Centered({ children }: { children: React.ReactNode }) {
  return (
    <Box contentAlignment="center" modifiers={[fillMaxSize(), padding(Spacing.five, Spacing.five, Spacing.five, Spacing.five)]}>
      <Column horizontalAlignment="center" verticalArrangement={{ spacedBy: Spacing.two }}>
        {children}
      </Column>
    </Box>
  );
}

/** Tonal grouped row: clipboard icon, the text, a relative timestamp, and a copy hint. */
function ClipRow({
  colors,
  icon,
  item,
  onPress,
  shape = groupShape(true, true),
}: {
  colors: MaterialColors;
  icon: { clipboard: IconSource; contentCopy: IconSource };
  item: ClipItem;
  onPress: () => void;
  shape?: RowShape;
}) {
  const t = tonal(colors, 'secondary');
  return (
    <Surface color={colors.surfaceContainerHigh} shape={shape} modifiers={[fillMaxWidth()]} onClick={onPress}>
      <ListItem colors={{ containerColor: 'transparent' }} modifiers={[fillMaxWidth()]}>
        <ListItem.LeadingContent>
          <IconCircle source={icon.clipboard} container={t.container} on={t.on} />
        </ListItem.LeadingContent>
        <ListItem.HeadlineContent>
          <Text color={colors.onSurface} style={{ typography: 'bodyLarge', fontWeight: '500' }}>
            {preview(item.text)}
          </Text>
        </ListItem.HeadlineContent>
        <ListItem.SupportingContent>
          <Text color={colors.onSurfaceVariant} style={{ typography: 'bodyMedium' }}>
            {formatRelative(item.ts)}
          </Text>
        </ListItem.SupportingContent>
        <ListItem.TrailingContent>
          <Icon source={icon.contentCopy} size={20} tint={colors.onSurfaceVariant} />
        </ListItem.TrailingContent>
      </ListItem>
    </Surface>
  );
}

/** Collapse whitespace and cap length so rows stay tidy. */
function preview(text: string): string {
  const oneLine = text.replace(/\s+/g, ' ').trim();
  return oneLine.length > 100 ? `${oneLine.slice(0, 100)}…` : oneLine;
}

/** "now" / "5m" / "2h" / "3d", else a short date. */
function formatRelative(ts: number): string {
  const diff = Date.now() - ts;
  if (diff < 0) return 'now';
  const min = Math.floor(diff / 60_000);
  if (min < 1) return 'now';
  if (min < 60) return `${min}m`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h`;
  const day = Math.floor(hr / 24);
  if (day < 7) return `${day}d`;
  return new Date(ts).toLocaleDateString();
}
