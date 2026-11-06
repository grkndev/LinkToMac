import { useRouter } from "expo-router";

import { useIcons } from "@/components/icons";
import { ActionRow, InlineNotice, SwitchRow } from "@/components/rows";
import { LargeTitle, Section, useM3Colors } from "@/components/m3";
import { M3Screen } from "@/components/m3-screen";
import { Spacing } from "@/constants/theme";
import SelfAdb from "@/features/selfadb/client";
import { useNotifFilterSummary } from "@/features/selfadb/use-notification-app-filter";
import { usePermissionSettings } from "@/features/selfadb/use-permission-settings";

/**
 * Notification settings, split by where the effect lands: the status-bar icon (this phone) and
 * mirroring to the Mac, with the per-app picker (notification-apps.tsx) while mirroring is on.
 */
export default function NotificationsScreen() {
  const router = useRouter();
  const colors = useM3Colors();
  const icons = useIcons();
  const filterSummary = useNotifFilterSummary();
  const {
    notifIconVisible,
    toggleNotifIcon,
    notifGranted,
    requestNotifPermission,
    notifMirrorOn,
    toggleNotifMirror,
    notifAccess,
  } = usePermissionSettings();

  const accessNotice =
    notifMirrorOn && notifAccess === false ? (
      <InlineNotice
        colors={colors}
        tone="tertiary"
        icon={icons.key}
        title="Grant notification access"
        message="Opens Android's Notification access settings"
        trailingIcon={icons.openInNew}
        onClick={() => {
          SelfAdb.openNotificationAccessSettings().catch(() => {});
        }}
      />
    ) : undefined;

  return (
    <M3Screen paddingTop={Spacing.one} spacing={Spacing.four}>
      <LargeTitle colors={colors}>Notifications</LargeTitle>

      <Section colors={colors} label="On this phone">
        <SwitchRow
          colors={colors}
          icon={icons.notificationsActive}
          tone="primary"
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
      </Section>

      <Section colors={colors} label="On your Mac">
        <SwitchRow
          colors={colors}
          icon={icons.screenShare}
          tone="primary"
          label="Mirror notifications"
          hint="Show this phone's notifications on your Mac"
          value={notifMirrorOn}
          onValueChange={toggleNotifMirror}
          footer={accessNotice}
        />
        {notifMirrorOn ? (
          <ActionRow
            colors={colors}
            icon={icons.apps}
            tone="primary"
            label="Select apps"
            hint={filterSummary ?? "Choose which apps are mirrored to your Mac."}
            onPress={() => router.push("/notification-apps")}
            chevron
          />
        ) : null}
      </Section>
    </M3Screen>
  );
}
