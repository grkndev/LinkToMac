import {
  Box,
  Column,
  Host,
  Icon,
  Shape,
  Surface,
  Text,
} from "@expo/ui/jetpack-compose";
import {
  fillMaxSize,
  fillMaxWidth,
  padding,
  size,
  verticalScroll,
} from "@expo/ui/jetpack-compose/modifiers";
import Constants from "expo-constants";
import * as Updates from "expo-updates";
import { useState } from "react";
import { Alert, Image, Linking, useColorScheme, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { useIcons } from "@/components/icons";
import { Group, SEED, useM3Colors } from "@/components/m3";
import { ActionRow, InfoRow } from "@/components/settings-rows";
import { Spacing } from "@/constants/theme";

const REPO_URL = "https://github.com/grkndev/LinkToMac";
const PROFILE_URL = "https://grkn.dev";
const RELEASES_URL = "https://github.com/grkndev/LinkToMac/releases";
const CONTACT_EMAIL = "info@grkn.dev";

/** 28dp "extra-large" rounded square for the expressive hero tile (matches Home). */
const HERO_SHAPE = Shape.RoundedCorner({
  cornerRadii: { topStart: 28, topEnd: 28, bottomStart: 28, bottomEnd: 28 },
});

const open = (url: string) => {
  Linking.openURL(url).catch(() => {});
};

/** About: app identity + version, developer, contact, and release notes. */
export default function AboutScreen() {
  const insets = useSafeAreaInsets();
  const scheme = useColorScheme();
  const colors = useM3Colors();
  const icons = useIcons();

  const version = Constants.expoConfig?.version ?? "—";

  const [checking, setChecking] = useState(false);

  // Manual OTA check: query EAS Update, then offer to download + restart. The whole flow is a
  // no-op outside release builds (Updates.isEnabled is false in dev / Expo Go).
  const checkForUpdates = async () => {
    if (checking) return;
    if (!Updates.isEnabled) {
      Alert.alert(
        "Updates unavailable",
        "Over-the-air updates only run in release builds.",
      );
      return;
    }
    setChecking(true);
    try {
      const result = await Updates.checkForUpdateAsync();
      if (!result.isAvailable) {
        Alert.alert("You're up to date", "No new update is available.");
        return;
      }
      Alert.alert("Update available", "Download it and restart the app now?", [
        { text: "Later", style: "cancel" },
        {
          text: "Update",
          onPress: async () => {
            try {
              await Updates.fetchUpdateAsync();
              await Updates.reloadAsync();
            } catch {
              Alert.alert(
                "Update failed",
                "Couldn't download the update. Try again later.",
              );
            }
          },
        },
      ]);
    } catch {
      Alert.alert(
        "Check failed",
        "Couldn't check for updates. Try again later.",
      );
    } finally {
      setChecking(false);
    }
  };

  return (
    <Host
      style={{ flex: 1, backgroundColor: colors.background }}
      seedColor={SEED}
      colorScheme={scheme}
    >
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
        verticalArrangement={{ spacedBy: Spacing.five }}
      >
        {/* Hero: app mark + name. */}
        <Column
          modifiers={[fillMaxWidth()]}
          horizontalAlignment="center"
          verticalArrangement={{ spacedBy: Spacing.two }}
        >

            <Image
              source={require("@/assets/images/icon.png")}
              className="aspect-square h-24 rounded-4xl"
              resizeMode="contain"
            />


          <Text
            color={colors.onSurface}
            style={{
              typography: "headlineLarge",
              fontWeight: "600",
              textAlign: "center",
            }}
          >
            Link To Mac
          </Text>
          <Text
            color={colors.onSurfaceVariant}
            style={{ typography: "bodyMedium", textAlign: "center" }}
          >
            Phone ↔ Mac clipboard & control
          </Text>
        </Column>

        {/* App info. */}
        <Group>
          <InfoRow
            colors={colors}
            icon={icons.info}
            label="App Version"
            value={version}
          />
        </Group>

        {/* Over-the-air updates. */}
        <Group>
          <ActionRow
            colors={colors}
            icon={icons.update}
            label="Check for updates"
            hint={
              checking
                ? "Checking…"
                : Updates.isEnabled
                  ? `Channel: ${Updates.channel ?? "—"}`
                  : "Available in release builds only."
            }
            onPress={checkForUpdates}
          />
        </Group>

        {/* Updates, source, developer, contact. */}
        <Group>
          <ActionRow
            colors={colors}
            icon={icons.sourcenotes}
            label="Release notes"
            hint="Changelog and latest releases on GitHub."
            onPress={() => open(RELEASES_URL)}
          />
          <ActionRow
            colors={colors}
            icon={icons.code}
            label="Source code"
            hint="github.com/grkndev/LinkToMac"
            onPress={() => open(REPO_URL)}
          />
          <ActionRow
            colors={colors}
            icon={icons.person}
            label="Developer"
            hint="grkndev · grkn.dev"
            onPress={() => open(PROFILE_URL)}
          />
          <ActionRow
            colors={colors}
            icon={icons.mail}
            label="Contact"
            hint={CONTACT_EMAIL}
            onPress={() => open(`mailto:${CONTACT_EMAIL}`)}
          />
        </Group>
      </Column>
    </Host>
  );
}
