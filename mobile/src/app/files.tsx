import { Box, Column, Icon, LoadingIndicator, Text } from "@expo/ui/jetpack-compose";
import {
  fillMaxWidth,
  padding,
  verticalScroll,
} from "@expo/ui/jetpack-compose/modifiers";
import { useNavigation } from "expo-router";
import { useLayoutEffect } from "react";
import { Alert } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { HeaderTextButton } from "@/components/header-button";
import { useIcons } from "@/components/icons";
import { ButtonGroup, Group, IconCircle, useM3Colors } from "@/components/m3";
import { M3Host } from "@/components/m3-screen";
import { ActionTile, GroupRow } from "@/components/rows";
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
      return `${folder}Cancelled`;
    default:
      return `${where} · ${folder}${formatBytes(e.size)} · ${formatRelative(e.ts)}`;
  }
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
        <ButtonGroup>
          <ActionTile
            colors={colors}
            icon={icons.file}
            label="Send files"
            enabled={connected}
            onPress={() => {
              haptic();
              SelfAdb.pickFiles().catch(() => {});
            }}
          />
          <ActionTile
            colors={colors}
            icon={icons.newFolder}
            label="Send folder"
            enabled={connected}
            onPress={() => {
              haptic();
              SelfAdb.pickFolder().catch(() => {});
            }}
          />
        </ButtonGroup>

        {/* What is going out right now. Tapping it cancels the batch (the same as the notification's Cancel). */}
        {current ? (
          <Group>
            <GroupRow
              colors={colors}
              icon={icons.upload}
              label={`${current.name} (${current.progress}%)`}
              supporting={
                inProgress.length > 1 ? `Sending to your Mac · ${inProgress.length - 1} more waiting` : "Sending to your Mac · tap to cancel"
              }
              onClick={() => {
                haptic();
                cancel();
              }}
              trailing={<Icon source={icons.close} size={20} tint={colors.onSurfaceVariant} />}
            />
          </Group>
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
          // Bounded (≤200) grouped list — a plain Column, not LazyColumn, since it sits inside the
          // outer verticalScroll() (infinite-height constraints crash a LazyColumn).
          <Group>
            {finished.map((e) => {
              const openable = e.direction === "in" && e.status === "done" && !!e.uri;
              const failed = e.status === "failed" || e.status === "cancelled";
              return (
                <GroupRow
                  key={e.id}
                  colors={colors}
                  icon={e.direction === "in" ? icons.download : icons.upload}
                  tone={failed ? "error" : "secondary"}
                  label={e.name}
                  supporting={describe(e)}
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
                      <Icon source={icons.retry} size={20} tint={colors.onSurfaceVariant} />
                    ) : undefined
                  }
                />
              );
            })}
          </Group>
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
