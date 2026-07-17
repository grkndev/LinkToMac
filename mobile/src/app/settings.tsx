import { useRouter } from "expo-router";
import { useState } from "react";

import { useIcons } from "@/components/icons";
import ConfirmSheet from "@/components/confirm-sheet";
import { ActionRow, InfoRow, SwitchRow } from "@/components/rows";
import { Group, useM3Colors } from "@/components/m3";
import { M3Screen } from "@/components/m3-screen";
import { Spacing } from "@/constants/theme";
import { usePairing } from "@/features/pairing/pairing-context";
import SelfAdb from "@/features/selfadb/client";
import { usePermissionSettings } from "@/features/selfadb/use-permission-settings";
import { Icon, RNHostView } from "@expo/ui/jetpack-compose";
import { View } from "react-native";

export default function SettingsScreen() {
  const router = useRouter();
  const { paused, setPaused, unpair } = usePairing();
  const colors = useM3Colors();
  const icons = useIcons();
  const [confirmingUnpair, setConfirmingUnpair] = useState(false);
  const {
    smsMirrorOn,
    toggleSmsMirror,
    smsAccess,
    requestSmsPermission,
    sendImagesOn,
    toggleSendImages,
    batteryOk,
    proximityOn,
    toggleProximity,
  } = usePermissionSettings();

  return (
    <>
      {/* One continuous Google-style grouped list — every row is a segment of a single rounded
        block (no section labels, no dividers). */}
      <M3Screen paddingTop={Spacing.three}>
        <Group>
          <ActionRow
            colors={colors}
            icon={icons.notifications}
            label="Notifications"
            hint="Status-bar icon, mirroring to your Mac, and which apps are mirrored."
            onPress={() => router.push("/notifications")}
            trailing={
              <Icon
                source={icons.chevronRight}
                size={24}
                tint={colors.onSurfaceVariant}
              />
            }
          />
          <SwitchRow
            colors={colors}
            icon={icons.chat}
            label="Mirror messages"
            hint="Read this phone's text messages on your Mac. Requires SMS access."
            value={smsMirrorOn}
            onValueChange={toggleSmsMirror}
          />
          {smsMirrorOn && smsAccess === false ? (
            <ActionRow
              colors={colors}
              icon={icons.chat}
              label="Grant SMS access"
              hint="Allow Link to macOS to read your messages and contacts so they can be shown on your Mac."
              onPress={requestSmsPermission}
            />
          ) : null}
          <SwitchRow
            colors={colors}
            icon={icons.contentCopy}
            label="Send copies"
            hint="Copies on this phone are sent to your Mac. You'll still receive the Mac's copies when off."
            value={!paused}
            onValueChange={(on) => setPaused(!on)}
          />
          <SwitchRow
            colors={colors}
            icon={icons.image}
            label="Send images"
            hint="Copied images are sent to your Mac's clipboard. You'll still receive the Mac's images when off."
            value={sendImagesOn}
            onValueChange={toggleSendImages}
          />
          <SwitchRow
            colors={colors}
            icon={icons.lock}
            label="Auto-lock"
            hint="Your Mac locks when this phone leaves range. Turn on the matching switch on your Mac too."
            value={proximityOn}
            onValueChange={toggleProximity}
          />
          {batteryOk === false ? (
            <ActionRow
              colors={colors}
              icon={icons.battery}
              label="Disable battery optimization"
              hint="Required for uninterrupted background operation."
              onPress={() => {
                SelfAdb.requestIgnoreBatteryOptimizations().catch(() => {});
              }}
              trailing={
                <Icon
                  source={icons.chevronRight}
                  size={24}
                  tint={colors.onSurfaceVariant}
                />
              }
            />
          ) : (
            <InfoRow
              colors={colors}
              icon={icons.battery}
              label="Battery Optimization"
              value={batteryOk ? "Disabled" : "—"}
            />
          )}
          <ActionRow
            colors={colors}
            icon={icons.cast}
            label="Relay server"
            hint="Set the server configuration."
            onPress={() => router.push("/server-config")}
            trailing={
              <Icon
                source={icons.chevronRight}
                size={24}
                tint={colors.onSurfaceVariant}
              />
            }
          />
          <ActionRow
            colors={colors}
            icon={icons.qr}
            label="Re-pair (Scan QR)"
            hint="Scan the Pairing QR from your Mac."
            onPress={() => router.push("/qr-scan")}
            trailing={
              <Icon
                source={icons.chevronRight}
                size={24}
                tint={colors.onSurfaceVariant}
              />
            }
          />
          <ActionRow
            colors={colors}
            icon={icons.linkOff}
            label="Remove Pairing"
            hint="Disconnect and remove the pairing."
            destructive
            onPress={() => setConfirmingUnpair(true)}
            trailing={
              <Icon
                source={icons.chevronRight}
                size={24}
                tint={colors.onSurfaceVariant}
              />
            }
          />
          <ActionRow
            colors={colors}
            icon={icons.terminal}
            label="Logs"
            hint="View ADB and device logs."
            onPress={() => router.push("/logs")}
            trailing={
              <Icon
                source={icons.chevronRight}
                size={24}
                tint={colors.onSurfaceVariant}
              />
            }
          />
          <ActionRow
            colors={colors}
            icon={icons.info}
            label="About"
            hint="Version, developer, and contact."
            onPress={() => router.push("/about")}
            trailing={
              <Icon
                source={icons.chevronRight}
                size={24}
                tint={colors.onSurfaceVariant}
              />
            }
          />
        </Group>
      </M3Screen>
      <ConfirmSheet
        visible={confirmingUnpair}
        onDismiss={() => setConfirmingUnpair(false)}
        onConfirm={() => unpair()}
        title="Remove pairing?"
        message="Your Mac will be disconnected and the pairing removed. To pair again, scan the QR code from your Mac."
        confirmLabel="Remove"
      />
    </>
  );
}
