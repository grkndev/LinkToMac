import { Column, Host } from "@expo/ui/jetpack-compose";
import {
  fillMaxWidth,
  padding,
  verticalScroll,
} from "@expo/ui/jetpack-compose/modifiers";
import { useRouter } from "expo-router";
import { useEffect, useRef, useState } from "react";
import { Alert, AppState, useColorScheme } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { useIcons } from "@/components/icons";
import { ActionRow, InfoRow, SwitchRow } from "@/components/settings-rows";
import { Group, SEED, useM3Colors } from "@/components/m3";
import { Spacing } from "@/constants/theme";
import { usePairing } from "@/features/relay/pairing-context";
import SelfAdb from "@/features/selfadb/client";

export default function SettingsScreen() {
  const router = useRouter();
  const { paused, setPaused, unpair } = usePairing();
  const insets = useSafeAreaInsets();
  const scheme = useColorScheme();
  const colors = useM3Colors();
  const icons = useIcons();

  const [notifIconVisible, setNotifIconVisible] = useState(true);
  const [notifGranted, setNotifGranted] = useState<boolean | null>(null);
  const [notifMirrorOn, setNotifMirrorOn] = useState(true);
  const [notifAccess, setNotifAccess] = useState<boolean | null>(null);
  const [smsMirrorOn, setSmsMirrorOn] = useState(true);
  const [smsAccess, setSmsAccess] = useState<boolean | null>(null);
  const [batteryOk, setBatteryOk] = useState<boolean | null>(null);
  const [proximityOn, setProximityOn] = useState(false);
  // True while a proximity toggle is mid-flight. The permission prompt below
  // backgrounds the app, so the AppState "active" re-check would otherwise read
  // a not-yet-started beacon and clobber the switch back OFF (issue #2).
  const togglingProximity = useRef(false);

  useEffect(() => {
    SelfAdb.getStatusNotificationVisible()
      .then(setNotifIconVisible)
      .catch(() => {});
    SelfAdb.hasPostNotifications()
      .then(setNotifGranted)
      .catch(() => setNotifGranted(null));
    SelfAdb.getNotificationForwarding()
      .then(setNotifMirrorOn)
      .catch(() => {});
    SelfAdb.hasNotificationAccess()
      .then(setNotifAccess)
      .catch(() => setNotifAccess(null));
    SelfAdb.getSmsForwarding()
      .then(setSmsMirrorOn)
      .catch(() => {});
    SelfAdb.hasSmsAccess()
      .then(setSmsAccess)
      .catch(() => setSmsAccess(null));
    SelfAdb.hasIgnoreBatteryOptimizations()
      .then(setBatteryOk)
      .catch(() => setBatteryOk(null));
    SelfAdb.getProximityAdvertise()
      .then(setProximityOn)
      .catch(() => {});

    // The battery exemption is granted in a system dialog/settings screen; re-check on return.
    const sub = AppState.addEventListener("change", (next) => {
      if (next !== "active") return;
      SelfAdb.hasIgnoreBatteryOptimizations()
        .then(setBatteryOk)
        .catch(() => {});
      SelfAdb.hasPostNotifications()
        .then(setNotifGranted)
        .catch(() => {});
      // "Notification access" is granted in a system settings screen -> re-check on return.
      SelfAdb.hasNotificationAccess()
        .then(setNotifAccess)
        .catch(() => {});
      // The READ_SMS/READ_CONTACTS runtime prompt backgrounds us -> re-check the grant on return.
      SelfAdb.hasSmsAccess()
        .then(setSmsAccess)
        .catch(() => {});
      // The OS may have revoked Nearby Devices behind our back -> reflect the real
      // beacon state. Skip while a toggle is in flight so we don't read the beacon
      // before it has started and snap the switch back OFF (issue #2).
      if (!togglingProximity.current) {
        SelfAdb.getProximityAdvertise()
          .then(setProximityOn)
          .catch(() => {});
      }
    });
    return () => sub.remove();
  }, []);

  const toggleNotifIcon = (visible: boolean) => {
    setNotifIconVisible(visible);
    SelfAdb.setStatusNotificationVisible(visible).catch(() => {});
  };

  const toggleNotifMirror = (on: boolean) => {
    setNotifMirrorOn(on);
    SelfAdb.setNotificationForwarding(on).catch(() => {});
  };

  const toggleSmsMirror = (on: boolean) => {
    setSmsMirrorOn(on);
    SelfAdb.setSmsForwarding(on).catch(() => {});
  };

  // Auto-lock needs Nearby Devices to advertise the BLE beacon; ask before enabling.
  const toggleProximity = (on: boolean) => {
    if (!on) {
      setProximityOn(false);
      SelfAdb.setProximityAdvertise(false).catch(() => {});
      return;
    }
    // Reflect the user's intent immediately, then hold the AppState re-check off
    // (togglingProximity) until the beacon has actually started, so the first tap
    // sticks even though the permission prompt backgrounds us (issue #2).
    togglingProximity.current = true;
    setProximityOn(true);
    SelfAdb.requestNearbyDevicesPermission()
      .then((granted) => {
        if (!granted) {
          setProximityOn(false);
          Alert.alert(
            "Permission needed",
            "Allow “Nearby devices” so your Mac can tell when this phone leaves.",
          );
          return;
        }
        return SelfAdb.setProximityAdvertise(true);
      })
      .catch(() => setProximityOn(false))
      .finally(() => {
        togglingProximity.current = false;
      });
  };

  const confirmUnpair = () => {
    Alert.alert(
      "Remove Pairing",
      "The pairing will be removed and the connection to the Mac will be disconnected. You will need to scan the QR code from your Mac to pair again.",
      [
        { text: "Cancel", style: "cancel" },
        { text: "Remove", style: "destructive", onPress: () => unpair() },
      ],
    );
  };

  return (
    <Host
      style={{ flex: 1, backgroundColor: colors.background }}
      seedColor={SEED}
      colorScheme={scheme}
    >
      {/* One continuous Google-style grouped list — every row is a segment of a single rounded
          block (no section labels, no dividers). A plain Column (not LazyColumn) is required:
          it lives inside the outer verticalScroll() Column, which passes infinite height
          constraints that crash a LazyColumn. */}
      <Column
        modifiers={[
          fillMaxWidth(),
          verticalScroll(),
          padding(
            Spacing.three,
            Spacing.three,
            Spacing.three,
            insets.bottom + Spacing.five,
          ),
        ]}
      >
        <Group>
          <SwitchRow
            colors={colors}
            icon={icons.notifications}
            label="Show notification icon"
            hint="A notification icon will be displayed in the status bar."
            value={notifIconVisible}
            onValueChange={toggleNotifIcon}
          />
          {notifGranted === false ? (
            <ActionRow
              colors={colors}
              icon={icons.notificationsActive}
              label="Grant notification permission"
              hint="Without permission, connection status notifications cannot be displayed."
              onPress={() => {
                SelfAdb.requestPostNotifications()
                  .then(setNotifGranted)
                  .catch(() => {});
              }}
            />
          ) : null}
          <SwitchRow
            colors={colors}
            icon={icons.notificationsActive}
            label="Mirror notifications"
            hint="Forward this phone's notifications to your Mac. Requires notification access."
            value={notifMirrorOn}
            onValueChange={toggleNotifMirror}
          />
          {notifMirrorOn && notifAccess === false ? (
            <ActionRow
              colors={colors}
              icon={icons.notifications}
              label="Grant notification access"
              hint="Allow Link to macOS to read notifications so they can be mirrored to your Mac."
              onPress={() => {
                SelfAdb.openNotificationAccessSettings().catch(() => {});
              }}
            />
          ) : null}
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
              onPress={() => {
                SelfAdb.requestSmsAccess()
                  .then(setSmsAccess)
                  .catch(() => {});
              }}
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
          />
          <ActionRow
            colors={colors}
            icon={icons.qr}
            label="Re-pair (Scan QR)"
            hint="Scan the Pairing QR from your Mac."
            onPress={() => router.push("/qr-scan")}
          />
          <ActionRow
            colors={colors}
            icon={icons.linkOff}
            label="Remove Pairing"
            hint="Disconnect and remove the pairing."
            destructive
            onPress={confirmUnpair}
          />
          <ActionRow
            colors={colors}
            icon={icons.terminal}
            label="Logs"
            hint="View ADB and device logs."
            onPress={() => router.push("/logs")}
          />
          <ActionRow
            colors={colors}
            icon={icons.info}
            label="About"
            hint="Version, developer, and contact."
            onPress={() => router.push("/about")}
          />
        </Group>
      </Column>
    </Host>
  );
}
