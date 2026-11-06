import {
  Box,
  Column,
  LoadingIndicator,
  } from "@expo/ui/jetpack-compose";
import { Text } from "@/components/text";
import {
  fillMaxSize,
  fillMaxWidth,
  padding,
  verticalScroll,
} from "@expo/ui/jetpack-compose/modifiers";
import { useNavigation } from "expo-router";
import { useLayoutEffect, useState } from "react";
import { Alert, ToastAndroid } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { HeaderTextButton } from "@/components/header-button";
import { useIcons } from "@/components/icons";
import { Group, IconCircle, useM3Colors } from "@/components/m3";
import { M3Host } from "@/components/m3-screen";
import { ClipRow } from "@/components/rows";
import { Spacing } from "@/constants/theme";
import { useClipHistory } from "@/features/clip-history/use-clip-history";
import SelfAdb from "@/features/selfadb/client";
import { haptic } from "@/lib/haptics";
import { formatAgo, looksLikeCode, preview } from "@/lib/text";

/** Clipboard items received from the paired Mac — newest first, tap any to copy it back. */
export default function ClipboardHistoryScreen() {
  const navigation = useNavigation();
  const insets = useSafeAreaInsets();
  const colors = useM3Colors();
  const icons = useIcons();
  const { items, clear } = useClipHistory();

  const hasItems = !!items && items.length > 0;

  // Stable keys (timestamp + occurrence): an index key remounted EVERY row when a new clip arrived.
  const seen = new Map<number, number>();
  const rows = (items ?? []).map((item) => {
    const n = seen.get(item.ts) ?? 0;
    seen.set(item.ts, n + 1);
    return { item, key: `${item.ts}-${n}` };
  });
  // The items present when the list first loaded; anything not in it arrived while the screen was
  // open and animates in. (Derived during render — guarded, so it settles in one pass.)
  const [baseline, setBaseline] = useState<Set<string> | null>(null);
  if (items && baseline === null) setBaseline(new Set(rows.map((r) => r.key)));

  // A "Clear" affordance in the native header, only while there's something to clear.
  useLayoutEffect(() => {
    navigation.setOptions({
      headerRight: hasItems
        ? () => (
            <HeaderTextButton
              label="Clear"
              color={colors.primary}
              onPress={() =>
                Alert.alert(
                  "Clear history",
                  "Remove all received clipboard items?",
                  [
                    { text: "Cancel", style: "cancel" },
                    { text: "Clear", style: "destructive", onPress: clear },
                  ],
                )
              }
            />
          )
        : undefined,
    });
  }, [navigation, hasItems, clear, colors.primary]);

  const copyBack = (text: string) => {
    SelfAdb.writeClipboard(text)
      .then(() => {
        haptic();
        ToastAndroid.show("Copied to this phone", ToastAndroid.SHORT);
      })
      .catch(() =>
        ToastAndroid.show(
          "Couldn't copy — connection not ready",
          ToastAndroid.SHORT,
        ),
      );
  };

  return (
    <M3Host>
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
          <Text
            color={colors.onSurface}
            style={{
              typography: "titleMedium",
              fontWeight: "600",
              textAlign: "center",
            }}
          >
            No clipboard items yet
          </Text>
          <Text
            color={colors.onSurfaceVariant}
            style={{ typography: "bodyMedium", textAlign: "center" }}
          >
            Items your Mac copies will show up here.
          </Text>
        </Centered>
      ) : (
        <Column
          modifiers={[
            fillMaxWidth(),
            verticalScroll(),
            padding(
              Spacing.three,
              Spacing.two,
              Spacing.three,
              insets.bottom + Spacing.five,
            ),
          ]}
        >
          <Box modifiers={[fillMaxWidth(), padding(Spacing.one, 0, Spacing.one, Spacing.three)]}>
            <Text color={colors.onSurfaceVariant} style={{ typography: "bodyMedium" }}>
              Copied on your Mac. Tap an item to copy it to this phone.
            </Text>
          </Box>
          {/* Bounded (≤100) grouped list — a plain Column, not LazyColumn, since it lives inside
              the outer verticalScroll() (infinite-height constraints crash a LazyColumn). */}
          <Group>
            {rows.map(({ item, key }, i) => (
              <ClipRow
                key={key}
                colors={colors}
                appear={baseline != null && !baseline.has(key)}
                latest={i === 0}
                text={preview(item.text, 200)}
                time={formatAgo(item.ts)}
                mono={looksLikeCode(item.text)}
                onPress={() => copyBack(item.text)}
              />
            ))}
          </Group>
        </Column>
      )}
    </M3Host>
  );
}

/** Centered single-column layout for the loading + empty states. */
function Centered({ children }: { children: React.ReactNode }) {
  return (
    <Box
      contentAlignment="center"
      modifiers={[
        fillMaxSize(),
        padding(Spacing.five, Spacing.five, Spacing.five, Spacing.five),
      ]}
    >
      <Column
        horizontalAlignment="center"
        verticalArrangement={{ spacedBy: Spacing.two }}
      >
        {children}
      </Column>
    </Box>
  );
}
