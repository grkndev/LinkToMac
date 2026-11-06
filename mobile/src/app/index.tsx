import {
  Box,
  Icon,
  Row,
  Shape,
  Surface,
  } from "@expo/ui/jetpack-compose";
import { Text } from "@/components/text";
import {
  fillMaxWidth,
  height,
  size,
  weight,
} from "@expo/ui/jetpack-compose/modifiers";
import { useRouter } from "expo-router";

import { Group, useM3Colors } from "@/components/m3";
import { M3Screen } from "@/components/m3-screen";
import { NavRow, QuickTile } from "@/components/rows";
import { StatusCard, type StatTileData } from "@/components/status-card";
import { useIcons } from "@/components/icons";
import { Spacing } from "@/constants/theme";
import { haptic } from "@/lib/haptics";
import { truncate } from "@/lib/text";
import SelfAdb from "@/features/selfadb/client";
import { useClipHistory } from "@/features/clip-history/use-clip-history";
import { useFileHistory } from "@/features/files/use-file-history";
import { useMacBattery } from "@/features/telemetry/use-mac-battery";
import { useMacDistance } from "@/features/telemetry/use-mac-distance";
import { usePairing } from "@/features/pairing/pairing-context";
import { useConnectionStatus } from "@/features/connection/use-connection-status";
import { useRelayStatus } from "@/features/connection/use-relay-status";

/** The round settings button in the top bar. */
const BUTTON_SHAPE = Shape.RoundedCorner({
  cornerRadii: { topStart: 24, topEnd: 24, bottomStart: 24, bottomEnd: 24 },
});

/** Home: the paired Mac and its live status in one card, plus quick actions and entry points. */
export default function HomeScreen() {
  const router = useRouter();
  const colors = useM3Colors();
  const icons = useIcons();
  const { pairing } = usePairing();
  const { relay } = useRelayStatus();
  const { items: clipItems } = useClipHistory();
  const { items: fileItems } = useFileHistory();
  const { battery } = useMacBattery();
  const { distance } = useMacDistance();

  const status = useConnectionStatus(relay);
  const connected = status.connected;

  const sending = fileItems?.some((e) => e.status === "active" || e.status === "queued");
  const filesValue =
    fileItems === null
      ? ""
      : sending
        ? "Sending…"
        : fileItems.length === 0
          ? "Send files or a folder"
          : `${fileItems.length} transfer${fileItems.length === 1 ? "" : "s"}`;

  const latestMacClip = clipItems?.[0]?.text;
  const clipValue = latestMacClip
    ? truncate(latestMacClip, 40)
    : clipItems === null
      ? ""
      : "No items received yet";

  // Stat tiles: only what the Mac has actually reported (a desktop Mac never sends a battery;
  // distance needs the Mac's proximity auto-lock on and this phone in range).
  const stats: StatTileData[] = [];
  if (status.transportLabel) {
    stats.push({
      key: "transport",
      icon: status.transportLabel === "LAN" ? icons.wifi : icons.dns,
      value: status.transportLabel,
      label: "Transport",
    });
  }
  if (battery) {
    stats.push({
      key: "battery",
      icon: icons.battery,
      value: `${battery.level}%`,
      label: battery.charging ? "Charging" : "Battery",
      accent: battery.charging,
    });
  }
  if (distance) {
    stats.push({
      key: "distance",
      icon: icons.sensors,
      value: distance.prox === "near" ? "Near" : "Away",
      label: distance.rssi != null ? `${distance.rssi} dBm` : "In range",
    });
  }

  return (
    <M3Screen safeTop paddingTop={0} spacing={Spacing.three}>
      {/* Top bar: title + settings entry point. */}
      <Row
        modifiers={[fillMaxWidth(), height(64)]}
        verticalAlignment="center"
      >
        <Text
          modifiers={[weight(1)]}
          color={colors.onSurface}
          style={{ typography: "titleLarge", fontSize: 22, fontWeight: "500" }}
        >
          Link to Mac
        </Text>
        <Surface
          color={colors.surfaceContainer}
          shape={BUTTON_SHAPE}
          onClick={() => router.push("/settings")}
          modifiers={[size(48, 48)]}
        >
          <Box contentAlignment="center" modifiers={[size(48, 48)]}>
            <Icon source={icons.settings} size={24} tint={colors.onSurface} />
          </Box>
        </Surface>
      </Row>

      <StatusCard
        colors={colors}
        name={pairing?.name ?? "Mac"}
        connected={connected}
        statusLabel={status.label}
        statusColor={status.color}
        stats={stats}
      />

      {/* Quick actions — Lock Mac is live (needs a connected Mac); Cast is a "Soon" placeholder. */}
      <Row modifiers={[fillMaxWidth()]} horizontalArrangement={{ spacedBy: Spacing.two }}>
        <QuickTile
          colors={colors}
          icon={icons.lock}
          label="Lock Mac"
          variant="filled"
          enabled={connected}
          onPress={() => {
            haptic();
            SelfAdb.sendCommand("lock").catch(() => {});
          }}
        />
        <QuickTile colors={colors} icon={icons.cast} label="Cast Screen" badge="Soon" />
      </Row>

      <Group>
        <NavRow
          colors={colors}
          icon={icons.folder}
          label="Files"
          value={filesValue}
          onClick={() => router.push("/files")}
        />
        <NavRow
          colors={colors}
          icon={icons.clipboard}
          label="Clipboard"
          value={clipValue}
          onClick={() => router.push("/clipboard-history")}
        />
      </Group>
    </M3Screen>
  );
}
