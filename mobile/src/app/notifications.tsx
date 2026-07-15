import { useRouter } from "expo-router";

import { useIcons } from "@/components/icons";
import { ActionRow, SwitchRow } from "@/components/rows";
import { Group, useM3Colors } from "@/components/m3";
import { M3Screen } from "@/components/m3-screen";
import { Spacing } from "@/constants/theme";
import SelfAdb from "@/features/selfadb/client";
import { usePermissionSettings } from "@/features/selfadb/use-permission-settings";

/**
 * Notification settings: the status-bar icon + mirroring toggles (moved out of Settings), plus
 * the entry point to the per-app mirroring picker (notification-apps.tsx) while mirroring is on.
 */
export default function NotificationsScreen() {
  const router = useRouter();
  const colors = useM3Colors();
  const icons = useIcons();
  const {
    notifIconVisible,
    toggleNotifIcon,
    notifGranted,
    requestNotifPermission,
    notifMirrorOn,
    toggleNotifMirror,
    notifAccess,
  } = usePermissionSettings();

  return (
    <M3Screen paddingTop={Spacing.three}>
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
            onPress={requestNotifPermission}
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
        {notifMirrorOn ? (
          <ActionRow
            colors={colors}
            icon={icons.apps}
            label="Select apps"
            hint="Choose which apps are mirrored to your Mac."
            onPress={() => router.push("/notification-apps")}
          />
        ) : null}
      </Group>
    </M3Screen>
  );
}
