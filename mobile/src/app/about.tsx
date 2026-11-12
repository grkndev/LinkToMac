import { Box, Column, Icon, Shape, Surface, } from "@expo/ui/jetpack-compose";
import { Text } from "@/components/text";
import { fillMaxWidth, padding, size } from "@expo/ui/jetpack-compose/modifiers";
import Constants from "expo-constants";
import * as Updates from "expo-updates";
import { Linking } from "react-native";

import { useIcons, type IconSource } from "@/components/icons";
import { Group, useM3Colors } from "@/components/m3";
import { M3Screen } from "@/components/m3-screen";
import { GroupRow, InfoRow } from "@/components/rows";
import { CONTACT_EMAIL, PROFILE_URL, RELEASES_URL, REPO_SLUG, REPO_URL } from "@/constants/links";
import { Spacing } from "@/constants/theme";
import { useAppUpdate } from "@/features/updates/use-app-update";

const open = (url: string) => {
  Linking.openURL(url).catch(() => {});
};

const MARK = Shape.RoundedCorner({
  cornerRadii: { topStart: 32, topEnd: 32, bottomStart: 32, bottomEnd: 32 },
});

/** About: app identity + version, updates, and links. */
export default function AboutScreen() {
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

  /** Plain (uncircled) leading glyph for the link rows — they read as links, not settings. */
  const glyph = (source: IconSource) => (
    <Icon source={source} size={22} tint={colors.onSurfaceVariant} />
  );
  const external = <Icon source={icons.openInNew} size={20} tint={colors.onSurfaceVariant} />;

  return (
    <M3Screen paddingTop={Spacing.one} spacing={Spacing.four}>
      {/* Hero: app mark + name. */}
      <Column
        modifiers={[fillMaxWidth(), padding(0, Spacing.two, 0, Spacing.two)]}
        horizontalAlignment="center"
        verticalArrangement={{ spacedBy: Spacing.two }}
      >
        <Surface color={colors.primary} shape={MARK} modifiers={[size(96, 96)]}>
          <Box contentAlignment="center" modifiers={[size(96, 96)]}>
            <Icon source={icons.link} size={48} tint={colors.onPrimary} />
          </Box>
        </Surface>
        <Box modifiers={[padding(0, Spacing.two, 0, 0)]}>
          <Text
            color={colors.onSurface}
            style={{ typography: "headlineMedium", fontSize: 28, fontWeight: "600", textAlign: "center" }}
          >
            Link to Mac
          </Text>
        </Box>
        <Text color={colors.onSurfaceVariant} style={{ typography: "bodyMedium", textAlign: "center" }}>
          Phone ↔ Mac clipboard & control
        </Text>
      </Column>

      {/* App info + OTA/native updates in one block. */}
      <Group>
        <InfoRow colors={colors} label="App version" value={version} />
        <InfoRow
          colors={colors}
          label="Build number"
          value={versionCode != null ? String(versionCode) : "—"}
          mono
        />
        <GroupRow
          colors={colors}
          label="Check for updates"
          labelColor={colors.primary}
          supporting={
            checking
              ? "Checking…"
              : Updates.isEnabled
                ? `Channel: ${
                    Constants.expoConfig?.name.includes("Dev")
                      ? "Development"
                      : (Updates.channel ?? "—")
                  }`
                : "Checks GitHub for a new app version."
          }
          trailing={<Icon source={icons.systemUpdate} size={22} tint={colors.primary} />}
          onClick={() => checkNow(true)}
        />
      </Group>

      <Group>
        <GroupRow
          colors={colors}
          leading={glyph(icons.article)}
          label="Release notes"
          trailing={external}
          onClick={() => open(RELEASES_URL)}
        />
        <GroupRow
          colors={colors}
          leading={glyph(icons.code)}
          label="Source code"
          supporting={`github.com/${REPO_SLUG}`}
          trailing={external}
          onClick={() => open(REPO_URL)}
        />
        <GroupRow
          colors={colors}
          leading={glyph(icons.person)}
          label="Developer"
          supporting="grkn.dev"
          trailing={external}
          onClick={() => open(PROFILE_URL)}
        />
        <GroupRow
          colors={colors}
          leading={glyph(icons.mail)}
          label="Contact"
          supporting={CONTACT_EMAIL}
          trailing={external}
          onClick={() => open(`mailto:${CONTACT_EMAIL}`)}
        />
      </Group>
    </M3Screen>
  );
}
