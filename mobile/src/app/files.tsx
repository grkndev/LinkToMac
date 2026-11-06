import {
  Box,
  Column,
  Icon,
  LinearProgressIndicator,
  LoadingIndicator,
  Row,
  Shape,
  Surface,
  type MaterialColors,
} from "@expo/ui/jetpack-compose";
import { Text } from "@/components/text";
import {
  alpha,
  fillMaxWidth,
  height,
  padding,
  verticalScroll,
  weight,
} from "@expo/ui/jetpack-compose/modifiers";
import { useNavigation } from "expo-router";
import { useLayoutEffect } from "react";
import { Alert } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { Alert as AppAlert } from "@/components/AlertDialog";
import { HeaderTextButton } from "@/components/header-button";
import { useIcons, type IconSource } from "@/components/icons";
import { Group, IconCircle, SectionLabel, useM3Colors, withAlpha } from "@/components/m3";
import { M3Host } from "@/components/m3-screen";
import { GroupRow } from "@/components/rows";
import { Spacing } from "@/constants/theme";
import { useRelayStatus } from "@/features/connection/use-relay-status";
import { useConnectionStatus } from "@/features/connection/use-connection-status";
import { useFileHistory } from "@/features/files/use-file-history";
import SelfAdb, { type FileTransferEntry } from "@/features/selfadb/client";
import { haptic } from "@/lib/haptics";
import { formatBytes, formatRelative } from "@/lib/text";

/** The second line of a row: where it went / came from, how big, and how it ended. */
function describe(e: FileTransferEntry): string {
  const where = e.direction === "in" ? "From your Mac" : "To your Mac";
  const folder = e.dir ? `${e.dir} · ` : "";
  switch (e.status) {
    case "queued":
      return `${folder}Waiting…`;
    case "active":
      return `${folder}Sending… ${e.progress}%`;
    case "failed":
      return `${folder}${e.error ?? "Failed"}`;
    case "cancelled":
      return `${where} · Cancelled`;
    default:
      return `${where} · ${folder}${formatBytes(e.size)} · ${formatRelative(e.ts)}`;
  }
}

/** Day bucket a finished row sits under. */
function dayBucket(ts: number): "Today" | "Yesterday" | "Earlier" {
  const startOfToday = new Date().setHours(0, 0, 0, 0);
  if (ts >= startOfToday) return "Today";
  if (ts >= startOfToday - 24 * 60 * 60 * 1000) return "Yesterday";
  return "Earlier";
}

/** Corner radii for the two send tiles: 28dp on the outside, 8dp where they meet. */
const sendShape = (first: boolean) => {
  const outer = 28;
  const inner = 8;
  return Shape.RoundedCorner({
    cornerRadii: first
      ? { topStart: outer, bottomStart: outer, topEnd: inner, bottomEnd: inner }
      : { topStart: inner, bottomStart: inner, topEnd: outer, bottomEnd: outer },
  });
};
const SEND_FIRST = sendShape(true);
const SEND_LAST = sendShape(false);
const CARD_SHAPE = Shape.RoundedCorner({
  cornerRadii: { topStart: 24, topEnd: 24, bottomStart: 24, bottomEnd: 24 },
});

/** "Send files" / "Send folder": a 56dp pill half; dimmed (and explanatory on tap) while offline. */
function SendTile({
  colors,
  icon,
  label,
  filled,
  enabled,
  onPress,
  shape,
}: {
  colors: MaterialColors;
  icon: IconSource;
  label: string;
  filled: boolean;
  enabled: boolean;
  onPress: () => void;
  shape: ReturnType<typeof sendShape>;
}) {
  const container = filled ? colors.primary : colors.secondaryContainer;
  const content = filled ? colors.onPrimary : colors.onSecondaryContainer;
  return (
    <Surface
      color={container}
      shape={shape}
      onClick={enabled ? onPress : () => AppAlert.show("Not connected", "Connect to your Mac first.", "OK")}
      modifiers={enabled ? [weight(1), height(56)] : [weight(1), height(56), alpha(0.5)]}
    >
      <Row
        modifiers={[fillMaxWidth(), height(56)]}
        horizontalArrangement="center"
        verticalAlignment="center"
      >
        <Row horizontalArrangement={{ spacedBy: Spacing.two }} verticalAlignment="center">
          <Icon source={icon} size={22} tint={content} />
          <Text color={content} style={{ typography: "labelLarge", fontSize: 15, fontWeight: "500" }}>
            {label}
          </Text>
        </Row>
      </Row>
    </Surface>
  );
}

/** Files that went to or came from the paired Mac — newest first — plus the buttons to send some. */
export default function FilesScreen() {
  const navigation = useNavigation();
  const insets = useSafeAreaInsets();
  const colors = useM3Colors();
  const icons = useIcons();
  const { items, clear, open, retry, cancel } = useFileHistory();
  const { relay } = useRelayStatus();
  const connected = useConnectionStatus(relay).connected;

  const hasItems = !!items && items.length > 0;
  const inProgress = items?.filter((e) => e.status === "active" || e.status === "queued") ?? [];
  const finished = items?.filter((e) => e.status !== "active" && e.status !== "queued") ?? [];
  const current = inProgress.find((e) => e.status === "active") ?? inProgress[0];

  // History arrives newest-first, so each bucket keeps that order.
  const buckets = (["Today", "Yesterday", "Earlier"] as const)
    .map((label) => ({ label, rows: finished.filter((e) => dayBucket(e.ts) === label) }))
    .filter((b) => b.rows.length > 0);

  useLayoutEffect(() => {
    navigation.setOptions({
      headerRight: finished.length
        ? () => (
            <HeaderTextButton
              label="Clear"
              color={colors.primary}
              onPress={() =>
                Alert.alert("Clear history", "Remove this list? The files themselves stay where they are.", [
                  { text: "Cancel", style: "cancel" },
                  { text: "Clear", style: "destructive", onPress: clear },
                ])
              }
            />
          )
        : undefined,
    });
  }, [navigation, finished.length, clear, colors.primary]);

  return (
    <M3Host>
      <Column
        modifiers={[
          fillMaxWidth(),
          verticalScroll(),
          padding(Spacing.three, Spacing.two, Spacing.three, insets.bottom + Spacing.five),
        ]}
        verticalArrangement={{ spacedBy: Spacing.three }}
      >
        <Row modifiers={[fillMaxWidth()]} horizontalArrangement={{ spacedBy: 4 }}>
          <SendTile
            colors={colors}
            icon={icons.uploadFile}
            label="Send files"
            filled
            enabled={connected}
            shape={SEND_FIRST}
            onPress={() => {
              haptic();
              SelfAdb.pickFiles().catch(() => {});
            }}
          />
          <SendTile
            colors={colors}
            icon={icons.uploadFolder}
            label="Send folder"
            filled={false}
            enabled={connected}
            shape={SEND_LAST}
            onPress={() => {
              haptic();
              SelfAdb.pickFolder().catch(() => {});
            }}
          />
        </Row>

        {/* What is going out right now. Tapping it cancels the batch (the same as the notification's Cancel). */}
        {current ? (
          <Surface
            color={colors.primaryContainer}
            shape={CARD_SHAPE}
            onClick={() => {
              haptic();
              cancel();
            }}
            modifiers={[fillMaxWidth()]}
          >
            <Column modifiers={[fillMaxWidth(), padding(16, 16, 16, 16)]} verticalArrangement={{ spacedBy: 12 }}>
              <Row
                modifiers={[fillMaxWidth()]}
                horizontalArrangement={{ spacedBy: 14 }}
                verticalAlignment="center"
              >
                <IconCircle
                  source={icons.upload}
                  container={colors.primary}
                  on={colors.onPrimary}
                />
                <Column modifiers={[weight(1)]} verticalArrangement={{ spacedBy: 2 }}>
                  <Text
                    color={colors.onPrimaryContainer}
                    style={{ typography: "bodyLarge", fontWeight: "600" }}
                    maxLines={1}
                    overflow="ellipsis"
                  >
                    {`${current.name} (${current.progress}%)`}
                  </Text>
                  <Text
                    color={withAlpha(colors.onPrimaryContainer, 0.85)}
                    style={{ typography: "bodySmall" }}
                  >
                    Sending to your Mac · tap to cancel
                  </Text>
                </Column>
                <Icon source={icons.close} size={22} tint={colors.onPrimaryContainer} />
              </Row>
              <LinearProgressIndicator
                progress={Math.max(0, Math.min(1, current.progress / 100))}
                color={colors.primary}
                trackColor={withAlpha(colors.primary, 0.22)}
                modifiers={[fillMaxWidth()]}
              />
              {inProgress.length > 1 ? (
                <Text color={withAlpha(colors.onPrimaryContainer, 0.85)} style={{ typography: "bodySmall" }}>
                  {`${inProgress.length - 1} more waiting`}
                </Text>
              ) : null}
            </Column>
          </Surface>
        ) : null}

        {items === null ? (
          <Centered>
            <LoadingIndicator color={colors.primary} />
          </Centered>
        ) : !hasItems ? (
          <Centered>
            <IconCircle
              source={icons.folder}
              container={colors.secondaryContainer}
              on={colors.onSecondaryContainer}
              diameter={72}
              iconSize={34}
            />
            <Text
              color={colors.onSurface}
              style={{ typography: "titleMedium", fontWeight: "600", textAlign: "center" }}
            >
              No transfers yet
            </Text>
            <Text color={colors.onSurfaceVariant} style={{ typography: "bodyMedium", textAlign: "center" }}>
              Send files or a folder from here, share to this app from any other, or drop files on your Mac.
            </Text>
          </Centered>
        ) : (
          // Bounded (≤200) grouped lists — plain Columns, not LazyColumn, since they sit inside the
          // outer verticalScroll() (infinite-height constraints crash a LazyColumn).
          buckets.map((b) => (
            <Column key={b.label} modifiers={[fillMaxWidth()]} verticalArrangement={{ spacedBy: Spacing.two }}>
              <SectionLabel colors={colors}>{b.label}</SectionLabel>
              <Group outerRadius={20}>
                {b.rows.map((e) => {
                  const openable = e.direction === "in" && e.status === "done" && !!e.uri;
                  const failed = e.status === "failed";
                  const cancelled = e.status === "cancelled";
                  return (
                    <GroupRow
                      key={e.id}
                      colors={colors}
                      icon={cancelled ? icons.block : e.direction === "in" ? icons.download : icons.upload}
                      // On the error card the badge is the strong error colour (a same-tone circle vanishes).
                      leading={
                        failed ? (
                          <IconCircle source={icons.error} container={colors.error} on={colors.onError} />
                        ) : undefined
                      }
                      tone={e.direction === "in" ? "tertiary" : "secondary"}
                      color={failed ? colors.errorContainer : undefined}
                      label={e.name}
                      labelColor={failed ? colors.onErrorContainer : cancelled ? colors.onSurfaceVariant : undefined}
                      supporting={describe(e)}
                      supportingColor={failed ? colors.onErrorContainer : undefined}
                      onClick={
                        openable
                          ? () => open(e)
                          : e.retryable
                            ? () => {
                                haptic();
                                retry(e);
                              }
                            : undefined
                      }
                      trailing={
                        openable ? (
                          <Icon source={icons.openInNew} size={20} tint={colors.onSurfaceVariant} />
                        ) : e.retryable ? (
                          <Icon
                            source={icons.retry}
                            size={22}
                            tint={failed ? colors.onErrorContainer : colors.onSurfaceVariant}
                          />
                        ) : undefined
                      }
                    />
                  );
                })}
              </Group>
            </Column>
          ))
        )}
      </Column>
    </M3Host>
  );
}

/** Centered single-column layout for the loading + empty states. */
function Centered({ children }: { children: React.ReactNode }) {
  return (
    <Box
      contentAlignment="center"
      modifiers={[fillMaxWidth(), padding(Spacing.five, Spacing.five, Spacing.five, Spacing.five)]}
    >
      <Column horizontalAlignment="center" verticalArrangement={{ spacedBy: Spacing.two }}>
        {children}
      </Column>
    </Box>
  );
}
