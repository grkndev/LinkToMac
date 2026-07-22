import { DarkTheme, DefaultTheme, Stack, ThemeProvider } from "expo-router";
import { useEffect, useMemo, type ComponentProps } from "react";
import { useColorScheme } from "react-native";
import { KeyboardProvider } from "react-native-keyboard-controller";
import * as SystemUI from "expo-system-ui";
import { StatusBar } from "expo-status-bar";

import { GlobalAlertDialog, alertRef } from '@/components/AlertDialog';
import { Booting } from "@/components/booting";
import { IconsProvider } from "@/components/icons";
import { useM3Colors } from "@/components/m3";
import { ReconnectBanner } from "@/components/reconnect-banner";
import { PairingProvider, usePairing } from "@/features/pairing/pairing-context";
import { useRelayAutostart } from "@/features/connection/use-relay-autostart";
import { useRelayStatus } from "@/features/connection/use-relay-status";
import {
  ClipBootProvider,
  useClipBootContext,
} from "@/features/selfadb/clip-boot-context";
import { AppUpdateProvider } from "@/features/updates/use-app-update";
import { UpdateModal } from "@/features/updates/update-modal";

export default function RootLayout() {
  const colorScheme = useColorScheme();
  const m3 = useM3Colors();

  // Paint the navigation container + every screen with the M3 background so the slide
  // transition never reveals the default white/black theme background before the native
  // Compose `Host` draws its first frame.
  const navTheme = useMemo(() => {
    const base = colorScheme === "dark" ? DarkTheme : DefaultTheme;
    return {
      ...base,
      colors: { ...base.colors, background: m3.background, card: m3.background },
    };
  }, [colorScheme, m3]);

  // Paint the Android window background too, so the slide transition can't flash the default
  // (white) window background through any gap before a screen's Compose `Host` draws.
  useEffect(() => {
    SystemUI.setBackgroundColorAsync(m3.background).catch(() => {});
  }, [m3.background]);

  return (
    <KeyboardProvider>
      <ThemeProvider value={navTheme}>
        <ClipBootProvider>
          <PairingProvider>
            <IconsProvider>
              <AppUpdateProvider>
                <StatusBar style="auto" />
                <RootNavigator background={m3.background} onSurface={m3.onSurface} />
                <UpdateModal />
                <GlobalAlertDialog ref={alertRef} />
              </AppUpdateProvider>
            </IconsProvider>
          </PairingProvider>
        </ClipBootProvider>
      </ThemeProvider>
    </KeyboardProvider>
  );
}

/**
 * Route gates, in priority order (screen declaration order decides where a guard
 * flip lands, so keep adb-setup -> pair-mac -> index):
 *   1. ADB pipeline not running AND the FGS link is down -> adb-setup (hard gate)
 *   2. ADB ready (or unreachable but the FGS link is alive, issue #29) -> pair-mac (QR scan
 *      entry) if not yet Mac-paired, else the app
 *   3. Paired -> home + settings
 * qr-scan sits outside the pairing guards so it serves both first pairing and re-pairing.
 */
function RootNavigator({
  background,
  onSurface,
}: {
  background: string;
  onSurface: string;
}) {
  const boot = useClipBootContext();
  const { pairing } = usePairing();
  const { relay } = useRelayStatus();

  useRelayAutostart();

  // The shared native-header recipe: flat, painted with the M3 background.
  type ScreenOptions = ComponentProps<typeof Stack.Screen>["options"];
  const header = (title: string, extras?: ScreenOptions): ScreenOptions => ({
    headerShown: true,
    headerTitle: title,
    headerShadowVisible: false,
    headerStyle: { backgroundColor: background },
    headerTintColor: onSurface,
    ...extras,
  });

  // Hold the Stack until boot + SecureStore settle so the guards don't flicker.
  if (boot.state === "booting" || pairing === undefined)
    return <Booting />;

  // need-connect/error only mean "the privileged clipboard daemon can't be (re)deployed over
  // ADB right now" — the FGS-owned features (relay/LAN link, remote lock, battery telemetry,
  // notification + SMS mirroring) don't need ADB at all and keep working behind what used to
  // be a full-screen dead end (issue #29 — hits every Mobile Hotspot session, since Wireless
  // Debugging can never come up while the phone is a Wi-Fi AP rather than a client). So only
  // hard-gate on need-pair (nothing works pre-pairing) and on need-connect/error while the
  // link is ALSO down; otherwise let the app through with a dismissible banner.
  const linkAlive = relay.peerOnline;
  const adbBlocked =
    boot.state === "need-pair" ||
    boot.state === "pairing" ||
    ((boot.state === "need-connect" || boot.state === "error") && !linkAlive);
  const adbBypassed = !adbBlocked && boot.state !== "ready";
  const macPaired = pairing != null;

  return (
    <>
      <ReconnectBanner visible={adbBypassed} onRetry={boot.refresh} />
      <Stack
        screenOptions={{
          animation: "fade",
          headerShown: false,
          contentStyle: { backgroundColor: background },
        }}
      >
        <Stack.Protected guard={adbBlocked}>
          <Stack.Screen name="adb-setup" />
        </Stack.Protected>
        <Stack.Protected guard={!adbBlocked}>
          <Stack.Protected guard={!macPaired}>
            <Stack.Screen name="pair-mac" />
          </Stack.Protected>
          <Stack.Protected guard={macPaired}>
            <Stack.Screen name="index" />
            <Stack.Screen name="settings" options={header("Settings")} />
            <Stack.Screen name="notifications" options={header("Notifications")} />
            <Stack.Screen name="notification-apps" options={header("Select apps")} />
            <Stack.Screen name="server-config" options={header("Relay server")} />
            {/* Logs never hid the header shadow — keep the platform default. */}
            <Stack.Screen
              name="logs"
              options={header("Logs", { headerShadowVisible: undefined })}
            />
            <Stack.Screen
              name="daemon-logs"
              options={header("Daemon Log", { headerShadowVisible: undefined })}
            />
            <Stack.Screen name="clipboard-history" options={header("Clipboard")} />
            <Stack.Screen name="about" options={header("About")} />
          </Stack.Protected>
          <Stack.Screen name="qr-scan" options={{ presentation: "modal" }} />
        </Stack.Protected>
      </Stack>
    </>
  );
}
