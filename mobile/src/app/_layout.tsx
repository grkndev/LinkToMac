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
import { PairingProvider, usePairing } from "@/features/pairing/pairing-context";
import { useRelayAutostart } from "@/features/connection/use-relay-autostart";
import { ClipBootProvider } from "@/features/selfadb/clip-boot-context";
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
 * Route gates, in priority order (screen declaration order decides where a guard flip lands,
 * so keep pair-mac -> index):
 *   1. Not Mac-paired -> pair-mac (QR scan entry)
 *   2. Paired -> home + settings, adb-setup among them
 * qr-scan sits outside the pairing guards so it serves both first pairing and re-pairing.
 *
 * Self-ADB is deliberately NOT a gate. It only buys automatic clipboard *capture*
 * (shell-UID daemon -> IClipboard.getPrimaryClip); the relay/LAN link, remote lock, battery
 * telemetry, notification + SMS mirroring and Mac->phone clipboard need none of it. Gating on
 * it held all of those hostage to a pairing that can't even be attempted off Wi-Fi (Wireless
 * Debugging never comes up on Mobile Hotspot, issue #29) and that adbd silently drops on a
 * Samsung reboot — stranding a working app on a full-screen dead end. A degraded capture path is reported
 * in Settings ("Automatic capture") and nowhere else — it's not urgent enough to interrupt
 * Home with a banner.
 */
function RootNavigator({
  background,
  onSurface,
}: {
  background: string;
  onSurface: string;
}) {
  const { pairing } = usePairing();

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

  // Hold the Stack until SecureStore settles so the pairing guard doesn't flicker. Capture
  // health is deliberately not part of this: autoStart() runs in the background and the app
  // renders without waiting on ADB.
  if (pairing === undefined) return <Booting />;

  const macPaired = pairing != null;

  return (
    <Stack
      screenOptions={{
        animation: "fade",
        headerShown: false,
        contentStyle: { backgroundColor: background },
      }}
    >
      <Stack.Protected guard={!macPaired}>
        <Stack.Screen name="pair-mac" />
      </Stack.Protected>
      <Stack.Protected guard={macPaired}>
        <Stack.Screen name="index" />
        <Stack.Screen name="settings" options={header("Settings")} />
        <Stack.Screen name="adb-setup" options={header("Automatic capture")} />
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
    </Stack>
  );
}
