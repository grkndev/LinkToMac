import {
  Box,
  Column,
  Icon,
  Row,
  Shape,
  Surface,
  Text,
} from "@expo/ui/jetpack-compose";
import {
  background,
  clip,
  fillMaxSize,
  fillMaxWidth,
  padding,
  Shapes,
  size,
} from "@expo/ui/jetpack-compose/modifiers";
import { useRouter } from "expo-router";

import { ButtonGroup, Group, useM3Colors } from "@/components/m3";
import { M3Screen } from "@/components/m3-screen";
import { ActionTile, NavRow } from "@/components/rows";
import { useIcons } from "@/components/icons";
import { Spacing } from "@/constants/theme";
import { haptic } from "@/lib/haptics";
import { truncate } from "@/lib/text";
import SelfAdb from "@/features/selfadb/client";
import { useClipHistory } from "@/features/clip-history/use-clip-history";
import { useMacBattery } from "@/features/telemetry/use-mac-battery";
import {
  macDistanceLabel,
  useMacDistance,
} from "@/features/telemetry/use-mac-distance";
import { usePairing } from "@/features/pairing/pairing-context";
import { useConnectionStatus } from "@/features/connection/use-connection-status";
import { useRelayStatus } from "@/features/connection/use-relay-status";

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
  const colors = useM3Colors();
  const icons = useIcons();
  const { pairing } = usePairing();
  const { relay } = useRelayStatus();
  const { items: clipItems } = useClipHistory();
  const { battery } = useMacBattery();
  const { distance } = useMacDistance();

  const status = useConnectionStatus(relay);
  const connected = status.connected;

  const latestMacClip = clipItems?.[0]?.text;
  const clipValue = latestMacClip
    ? truncate(latestMacClip, 40)
    : clipItems === null
      ? ""
      : "No items received yet";

  return (
    <M3Screen safeTop spacing={Spacing.five}>
        {/* Top bar: settings entry point. */}
        <Row modifiers={[fillMaxWidth()]} horizontalArrangement="end">
          <Surface
            color={colors.surfaceContainerHigh}
            shape={HERO_SHAPE}
            onClick={() => router.push("/settings")}
            modifiers={[size(44, 44)]}
          >
            <Box contentAlignment="center" modifiers={[fillMaxSize()]}>
              <Icon
                source={icons.settings}
                size={24}
                tint={colors.onSurfaceVariant}
              />
            </Box>
          </Surface>
        </Row>

        {/* Hero: the paired Mac's identity + live connection status. */}
        <Column
          modifiers={[fillMaxWidth()]}
          horizontalAlignment="center"
          verticalArrangement={{ spacedBy: Spacing.two }}
        >
          <Surface
            color={colors.secondaryContainer}
            shape={HERO_SHAPE}
            modifiers={[size(96, 96)]}
          >
            <Box contentAlignment="center" modifiers={[fillMaxSize()]}>
              <Icon
                source={icons.laptop}
                size={46}
                tint={colors.onSecondaryContainer}
              />
            </Box>
          </Surface>
          <Text
            color={colors.onSurface}
            style={{
              typography: "headlineSmall",
              fontWeight: "600",
              textAlign: "center",
            }}
          >
            {pairing?.name ?? "Mac"}
          </Text>
         
          <Row
            verticalAlignment="center"
            horizontalArrangement={{ spacedBy: Spacing.two }}
          >
            {connected && status.transportLabel ? (
              <Surface color={colors.secondaryContainer} shape={CHIP_SHAPE}>
                <Box
                  modifiers={[
                    padding(Spacing.two, Spacing.one, Spacing.two, Spacing.one),
                  ]}
                >
                  <Text
                    color={colors.onSecondaryContainer}
                    style={{ typography: "labelMedium", fontWeight: "700" }}
                  >
                    {status.transportLabel}
                  </Text>
                </Box>
              </Surface>
            ) : null}
            {/* Mac battery — only when connected and the Mac has reported one (desktop Macs never do).
                A charging Mac uses the tertiary tone so plugged-in reads at a glance. */}
            {connected && battery ? (
              <Surface
                color={
                  battery.charging
                    ? colors.tertiaryContainer
                    : colors.secondaryContainer
                }
                shape={CHIP_SHAPE}
              >
                <Row
                  verticalAlignment="center"
                  horizontalArrangement={{ spacedBy: Spacing.one }}
                  modifiers={[
                    padding(Spacing.two, Spacing.one, Spacing.two, Spacing.one),
                  ]}
                >
                  <Icon
                    source={icons.battery}
                    size={14}
                    tint={
                      battery.charging
                        ? colors.onTertiaryContainer
                        : colors.onSecondaryContainer
                    }
                  />
                  <Text
                    color={
                      battery.charging
                        ? colors.onTertiaryContainer
                        : colors.onSecondaryContainer
                    }
                    style={{ typography: "labelMedium", fontWeight: "700" }}
                  >
                    {`${battery.level}%`}
                  </Text>
                </Row>
              </Surface>
            ) : null}
          </Row>

          {/* BLE distance the Mac measured for this phone (it can't measure that itself — it only
              advertises). Sits between the connection type (chips) and status; only present while
              the Mac's proximity auto-lock is on and the phone is in range. */}
          {connected && distance ? (
            <Row
              verticalAlignment="center"
              horizontalArrangement={{ spacedBy: Spacing.one }}
            >
              <Icon
                source={icons.sensors}
                size={16}
                tint={colors.onSurfaceVariant}
              />
              <Text
                color={colors.onSurfaceVariant}
                style={{ typography: "labelLarge", fontWeight: "600" }}
              >
                {macDistanceLabel(distance)}
              </Text>
            </Row>
          ) : null}

           <Row
            verticalAlignment="center"
            horizontalArrangement={{ spacedBy: Spacing.two }}
          >
            <Box
              modifiers={[
                size(8, 8),
                clip(Shapes.Circle),
                background(status.color),
              ]}
            />
            <Text
              color={colors.onSurfaceVariant}
              style={{ typography: "labelLarge", fontWeight: "600" }}
            >
              {status.label}
            </Text>
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
              haptic();
              SelfAdb.sendCommand("lock").catch(() => {});
            }}
          />
          <ActionTile colors={colors} icon={icons.cast} label="Cast Screen" />
        </ButtonGroup>
          

        {/* Info list — same grouped-list language as Settings. */}
        <Group>
          <NavRow
            colors={colors}
            icon={icons.folder}
            label="Received files"
            value="Soon"
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
