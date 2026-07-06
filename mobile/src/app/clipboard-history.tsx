import {
  Box,
  Column,
  LoadingIndicator,
  Text,
} from "@expo/ui/jetpack-compose";
import {
  fillMaxSize,
  fillMaxWidth,
  padding,
  verticalScroll,
} from "@expo/ui/jetpack-compose/modifiers";
import { useNavigation } from "expo-router";
import { useLayoutEffect } from "react";
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
import { formatRelative, preview } from "@/lib/text";

/** Clipboard items received from the paired Mac — newest first, tap any to copy it back. */
export default function ClipboardHistoryScreen() {
  const navigation = useNavigation();
  const insets = useSafeAreaInsets();
  const colors = useM3Colors();
  const icons = useIcons();
  const { items, clear } = useClipHistory();

  const hasItems = !!items && items.length > 0;

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
      .then(haptic)
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
          {/* Bounded (≤100) grouped list — a plain Column, not LazyColumn, since it lives inside
              the outer verticalScroll() (infinite-height constraints crash a LazyColumn). */}
          <Group>
            {items.map((item, i) => (
              <ClipRow
                key={`${item.ts}-${i}`}
                colors={colors}
                icon={icons.clipboard}
                trailingIcon={icons.contentCopy}
                text={preview(item.text, 100)}
                time={formatRelative(item.ts)}
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
