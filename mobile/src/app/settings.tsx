import { Icon } from "@expo/ui/jetpack-compose";
import Constants from "expo-constants";
import { useRouter } from "expo-router";
import { useEffect, useState } from "react";

import { useCollapsingTitle } from "@/components/collapsing-title";
import { useIcons } from "@/components/icons";
import ConfirmSheet from "@/components/confirm-sheet";
import { ActionRow, InfoRow, InlineNotice, SwitchRow } from "@/components/rows";
import { Group, LargeTitle, Section, useM3Colors } from "@/components/m3";
import { M3Screen } from "@/components/m3-screen";
import { Spacing, StatusColors } from "@/constants/theme";
import { COLOR_LABELS } from "@/features/appearance/appearance-store";
import { useAppearance } from "@/features/appearance/appearance-context";
import { usePairing } from "@/features/pairing/pairing-context";
import SelfAdb from "@/features/selfadb/client";
import { useClipBootContext } from "@/features/selfadb/clip-boot-context";
import type { CaptureState } from "@/features/selfadb/use-clip-boot";
import { usePermissionSettings } from "@/features/selfadb/use-permission-settings";

/** Row hint per capture state — the self-ADB pipeline's health, reported not gated on. */
const CAPTURE_HINT: Record<CaptureState, string> = {
  live: "On. Copies on this phone reach your Mac without a tap.",
  starting: "Checking…",
  pairing: "Setting up…",
  "needs-setup": "Off. Set it up to send copies without a tap.",
  error: "Off. Something went wrong — tap for details.",
};

/** The status dot beside the capture hint: green when on, amber while working, red on error. */
function captureDot(state: CaptureState, neutral: string): string {
  switch (state) {
    case "live":
      return StatusColors.online;
    case "starting":
    case "pairing":
      return StatusColors.warn;
    case "error":
      return StatusColors.error;
    default:
      return neutral;
  }
}

/** Shown in the SMS notice once Android has refused to prompt (see usePermissionSettings). */
const BLOCKED_HINT =
  "Android blocked the prompt. Finish in App info: allow restricted settings, then grant SMS.";

const MODE_LABELS = { system: "System", light: "Light", dark: "Dark" } as const;

export default function SettingsScreen() {
  const { onTitleLayout, topInset, backdrop } = useCollapsingTitle("Settings");
  const router = useRouter();
  const { unpair, server } = usePairing();
  const colors = useM3Colors();
  const icons = useIcons();
  const appearance = useAppearance();
  const [confirmingUnpair, setConfirmingUnpair] = useState(false);
  const capture = useClipBootContext();
  const {
    smsMirrorOn,
    toggleSmsMirror,
    smsAccess,
    requestSmsPermission,
    sendSmsAccess,
    requestSendSmsPermission,
    smsBlocked,
    batteryOk,
    proximityOn,
    toggleProximity,
  } = usePermissionSettings();

  // Automatic app-update downloads (native AppUpdater). Null until read — and stays null on a
  // binary that predates the updater, which hides the row instead of showing a dead switch.
  const [autoUpdate, setAutoUpdate] = useState<boolean | null>(null);
  useEffect(() => {
    if (typeof SelfAdb.getAutoUpdate !== "function") return;
    let cancelled = false;
    SelfAdb.getAutoUpdate()
      .then((v) => !cancelled && setAutoUpdate(v))
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, []);

  // One notice at a time under "Mirror messages": reading first, then replying.
  const smsNotice =
    smsMirrorOn && smsAccess === false ? (
      <InlineNotice
        colors={colors}
        icon={icons.gppMaybe}
        title="Grant SMS access"
        message={
          smsBlocked
            ? BLOCKED_HINT
            : "Allow Link to macOS to read your messages and contacts so they can be shown on your Mac."
        }
        actionLabel={smsBlocked ? "Open App info" : "Grant access"}
        onClick={
          smsBlocked ? () => SelfAdb.openAppSettings().catch(() => {}) : requestSmsPermission
        }
      />
    ) : smsMirrorOn && sendSmsAccess === false ? (
      <InlineNotice
        colors={colors}
        icon={icons.gppMaybe}
        title="Grant SMS Send Access"
        message={
          smsBlocked
            ? BLOCKED_HINT
            : "Allow Link to macOS to send text messages so you can reply from your Mac."
        }
        actionLabel={smsBlocked ? "Open App info" : "Grant access"}
        onClick={
          smsBlocked
            ? () => SelfAdb.openAppSettings().catch(() => {})
            : requestSendSmsPermission
        }
      />
    ) : undefined;

  const relayHint = `${server?.host ? server.host : "LAN only"} · LAN-direct ${
    server?.lanEnabled === false ? "off" : "on"
  }`;
  const appearanceHint = `${MODE_LABELS[appearance.mode]} · ${COLOR_LABELS[appearance.color]}`;

  return (
    <>
      <M3Screen paddingTop={topInset + Spacing.one} spacing={Spacing.four}>
        <LargeTitle colors={colors} onLayoutChange={onTitleLayout}>
          Settings
        </LargeTitle>

        <Section colors={colors} label="Mirroring">
          <ActionRow
            colors={colors}
            icon={icons.notifications}
            tone="primary"
            label="Notifications"
            hint="Status-bar icon, mirroring to your Mac, and which apps are mirrored."
            onPress={() => router.push("/notifications")}
            chevron
          />
          <SwitchRow
            colors={colors}
            icon={icons.sms}
            tone="primary"
            label="Mirror messages"
            hint="Show SMS on your Mac"
            value={smsMirrorOn}
            onValueChange={toggleSmsMirror}
            footer={smsNotice}
          />
          <ActionRow
            colors={colors}
            icon={icons.pasteGo}
            tone="primary"
            label="Automatic capture"
            hint={CAPTURE_HINT[capture.state]}
            supportingDot={captureDot(capture.state, colors.outline)}
            onPress={() => router.push("/adb-setup")}
            chevron
          />
        </Section>

        <Section colors={colors} label="Mac">
          <SwitchRow
            colors={colors}
            icon={icons.lockClock}
            tone="tertiary"
            label="Auto-lock"
            hint="Lock your Mac when this phone leaves range. Turn it on on your Mac too."
            value={proximityOn}
            onValueChange={toggleProximity}
          />
        </Section>

        <Section colors={colors} label="Connection">
          <ActionRow
            colors={colors}
            icon={icons.dns}
            label="Relay server"
            hint={relayHint}
            onPress={() => router.push("/server-config")}
            chevron
          />
          <ActionRow
            colors={colors}
            icon={icons.qr}
            label="Re-pair"
            hint="Scan the QR code again"
            onPress={() => router.push("/qr-scan")}
            chevron
          />
        </Section>

        <Section colors={colors} label="System">
          <ActionRow
            colors={colors}
            icon={icons.palette}
            label="Appearance"
            hint={appearanceHint}
            onPress={() => router.push("/appearance")}
            chevron
          />
          {autoUpdate !== null ? (
            <SwitchRow
              colors={colors}
              icon={icons.systemUpdate}
              label="Download updates automatically"
              hint="Fetches new versions in the background. You still confirm the install."
              value={autoUpdate}
              onValueChange={(v) => {
                setAutoUpdate(v);
                SelfAdb.setAutoUpdate(v).catch(() => {});
              }}
            />
          ) : null}
          {batteryOk === false ? (
            <ActionRow
              colors={colors}
              icon={icons.batterySaver}
              label="Disable battery optimization"
              hint="Keeps the link alive in the background"
              onPress={() => {
                SelfAdb.requestIgnoreBatteryOptimizations().catch(() => {});
              }}
              trailing={
                <Icon source={icons.openInNew} size={20} tint={colors.onSurfaceVariant} />
              }
            />
          ) : (
            <InfoRow
              colors={colors}
              icon={icons.batterySaver}
              label="Battery optimization"
              value={batteryOk ? "Disabled" : "—"}
            />
          )}
        </Section>

        <Section colors={colors} label="Support">
          <ActionRow
            colors={colors}
            icon={icons.terminal}
            label="Logs"
            onPress={() => router.push("/logs")}
            chevron
          />
          <ActionRow
            colors={colors}
            icon={icons.info}
            label="About"
            hint={`Version ${Constants.expoConfig?.version ?? "—"}`}
            onPress={() => router.push("/about")}
            chevron
          />
        </Section>

        <Group>
          <ActionRow
            colors={colors}
            icon={icons.linkOff}
            label="Remove pairing"
            destructive
            onPress={() => setConfirmingUnpair(true)}
          />
        </Group>
      </M3Screen>
      {backdrop}
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
