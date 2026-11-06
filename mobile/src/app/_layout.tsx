import { DarkTheme, DefaultTheme, Stack, ThemeProvider } from "expo-router";
import { useFonts } from "expo-font";
import { useEffect, useMemo, type ComponentProps } from "react";
import { useColorScheme } from "react-native";
import { KeyboardProvider } from "react-native-keyboard-controller";
import * as SystemUI from "expo-system-ui";
import { StatusBar } from "expo-status-bar";

import { GlobalAlertDialog, alertRef } from '@/components/AlertDialog';
import { Booting } from "@/components/booting";
import { IconsProvider } from "@/components/icons";
import { useM3Colors } from "@/components/m3";
import { FONT_ASSETS, SANS } from "@/constants/typography";
import { AppearanceProvider, useAppearance } from "@/features/appearance/appearance-context";
import { PairingProvider, usePairing } from "@/features/pairing/pairing-context";
import { useRelayAutostart } from "@/features/connection/use-relay-autostart";
import { ClipBootProvider } from "@/features/selfadb/clip-boot-context";
import { AppUpdateProvider } from "@/features/updates/use-app-update";
import { UpdateModal } from "@/features/updates/update-modal";

export default function RootLayout() {
  // The appearance preference sits outermost: the navigation theme, StatusBar and every Compose
  // Host below read the palette (light/dark + accent colour) through it.
  return (
    <AppearanceProvider>
      <ThemedRoot />
    </AppearanceProvider>
  );
}

function ThemedRoot() {
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
  const { ready: appearanceReady } = useAppearance();
  // Compose `Text` picks Google Sans Flex / JetBrains Mono by family name, so they must be
  // registered before the first frame. A load error falls through (system font beats a stuck spinner).
  const [fontsLoaded, fontError] = useFonts(FONT_ASSETS);

  useRelayAutostart();

  // The shared native-header recipe: flat, painted with the M3 background.
  type ScreenOptions = ComponentProps<typeof Stack.Screen>["options"];
  const header = (title: string, extras?: ScreenOptions): ScreenOptions => ({
    headerShown: true,
    headerTitle: title,
    headerShadowVisible: false,
    headerStyle: { backgroundColor: background },
    headerTintColor: onSurface,
    headerTitleStyle: { fontFamily: SANS.regular, fontSize: 22 },
    ...extras,
  });

  // Hold the Stack until SecureStore settles so the pairing guard doesn't flicker. Capture
  // health is deliberately not part of this: autoStart() runs in the background and the app
  // renders without waiting on ADB.
  // The saved theme is held too, so the first frame is already in the chosen colours.
  if (pairing === undefined || !appearanceReady || !(fontsLoaded || fontError)) return <Booting />;

  const macPaired = pairing != null;

  return (
    <Stack
      screenOptions={{
        // A translate-only transition on purpose (was `fade`). Suspected cause of the ripple bug — a
        // press on a Settings row froze its ripple half-way on the FIRST press after returning to the
        // screen: an alpha (fade) transition puts the animating screen on a temporary hardware layer,
        // translate animations don't. Unconfirmed until verified on a device; see mobile/CLAUDE.md.
        animation: "slide_from_right",
        headerShown: false,
        contentStyle: { backgroundColor: background },
      }}
    >
      <Stack.Protected guard={!macPaired}>
        <Stack.Screen name="pair-mac" />
      </Stack.Protected>
      <Stack.Protected guard={macPaired}>
        <Stack.Screen name="index" />
        {/* Settings / Notifications draw a 34sp LargeTitle in the body; the header is just the back arrow. */}
        <Stack.Screen name="settings" options={header("")} />
        <Stack.Screen name="appearance" options={header("Appearance")} />
        <Stack.Screen name="adb-setup" options={header("Automatic capture")} />
        <Stack.Screen name="notifications" options={header("")} />
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
        <Stack.Screen name="files" options={header("Files")} />
        <Stack.Screen name="about" options={header("")} />
      </Stack.Protected>
      <Stack.Screen name="qr-scan" options={{ presentation: "modal" }} />
    </Stack>
  );
}
