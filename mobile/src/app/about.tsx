import { Column, Host, Text } from "@expo/ui/jetpack-compose";
import {
  fillMaxWidth,
  padding,
  verticalScroll,
} from "@expo/ui/jetpack-compose/modifiers";
import Constants from "expo-constants";
import * as Updates from "expo-updates";
import { Image, Linking, useColorScheme } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { useIcons } from "@/components/icons";
import { Group, SEED, useM3Colors } from "@/components/m3";
import { ActionRow, InfoRow } from "@/components/settings-rows";
import { Spacing } from "@/constants/theme";
import { useAppUpdate } from "@/features/updates/use-app-update";

const REPO_URL = "https://github.com/grkndev/LinkToMac";
const PROFILE_URL = "https://grkn.dev";
const RELEASES_URL = "https://github.com/grkndev/LinkToMac/releases";
const CONTACT_EMAIL = "info@grkn.dev";

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
  // versionCode read from the resolved config. SDK 56's expo-constants no longer exposes the
  // native versionCode (Constants.platform.android is an empty map), and the truly-native
  // source (expo-application) is a native module we'd have to add — which wouldn't ship over
  // OTA. Caveat of the config path + our date-based YYMMDDNNN scheme: after an OTA this shows
  // that update's *publish-date* code rather than the APK's build date. Close enough for a
  // build identifier, and it stays OTA-deliverable.
  const versionCode = Constants.expoConfig?.android?.versionCode;

  // Manual check routed through the shared updater: it surfaces the same modal as the launch check
  // (OTA → download + restart, or a newer native APK → release download). See use-app-update.
  const { checking, checkNow } = useAppUpdate();

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
          <InfoRow
            colors={colors}
            icon={icons.terminal}
            label="Build number"
            value={versionCode != null ? String(versionCode) : "—"}
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
                  ? `Channel: ${
                    Constants.expoConfig?.name.includes("Dev") ? "Development" :
                    Updates.channel ?? "—"}`
                  : "Checks GitHub for a new app version."
            }
            onPress={() => checkNow(true)}
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
