import { DarkTheme, DefaultTheme, Stack, ThemeProvider } from "expo-router";
import { useEffect, useMemo } from "react";
import { StyleSheet, useColorScheme } from "react-native";
import { KeyboardProvider } from "react-native-keyboard-controller";
import * as SystemUI from "expo-system-ui";
import {
  Host,
  LoadingIndicator,
  Box,
  Surface,
  Shape,
} from "@expo/ui/jetpack-compose";

import { IconsProvider } from "@/components/icons";
import { ThemedText } from "@/components/themed-text";
import { ThemedView } from "@/components/themed-view";
import { Spacing } from "@/constants/theme";
import { PairingProvider, usePairing } from "@/features/relay/pairing-context";
import { useRelayAutostart } from "@/features/relay/use-relay-autostart";
import {
  ClipBootProvider,
  useClipBootContext,
} from "@/features/selfadb/clip-boot-context";
import { StatusBar } from "expo-status-bar";
import { SEED, useM3Colors } from "@/components/m3";
import { fillMaxSize, size } from "@expo/ui/jetpack-compose/modifiers";

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
              <StatusBar style="auto" />
              <RootNavigator background={m3.background} onSurface={m3.onSurface} />
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
 *   1. ADB pipeline not running (never paired / wireless debugging off / error) -> adb-setup
 *   2. ADB ready but no Mac pairing -> pair-mac (QR scan entry)
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

  useRelayAutostart();

  // Hold the Stack until boot + SecureStore settle so the guards don't flicker.
  if (boot.state === "booting" || pairing === undefined)
    return <Booting />;

  const adbReady = boot.state === "ready";
  const macPaired = pairing != null;

  return (
    <Stack
      screenOptions={{
        animation:"fade",
        headerShown: false,
        contentStyle: { backgroundColor: background },
      }}
    >
      <Stack.Protected guard={!adbReady}>
        <Stack.Screen name="adb-setup" />
      </Stack.Protected>
      <Stack.Protected guard={adbReady}>
        <Stack.Protected guard={!macPaired}>
          <Stack.Screen name="pair-mac" />
        </Stack.Protected>
        <Stack.Protected guard={macPaired}>
          <Stack.Screen name="index" />
          <Stack.Screen
            name="settings"
            options={{
              headerShown: true,
              headerTitle: "Settings",
              headerShadowVisible: false,
              headerStyle: { backgroundColor: background },
              headerTintColor: onSurface,
            }}
          />
          <Stack.Screen
            name="server-config"
            options={{
              headerShown: true,
              headerTitle: "Relay server",
              headerShadowVisible: false,
              headerStyle: { backgroundColor: background },
              headerTintColor: onSurface,
            }}
          />
          <Stack.Screen
            name="logs"
            options={{
              headerShown: true,
              title: "Logs",
              headerStyle: { backgroundColor: background },
              headerTintColor: onSurface,
            }}
          />
          <Stack.Screen
            name="clipboard-history"
            options={{
              headerShown: true,
              title: "Clipboard",
              headerShadowVisible: false,
              headerStyle: { backgroundColor: background },
              headerTintColor: onSurface,
            }}
          />
        </Stack.Protected>
        <Stack.Screen name="qr-scan" options={{ presentation: "modal" }} />
      </Stack.Protected>
    </Stack>
  );
}

function Booting() {
  const colors = useM3Colors();
  const scheme = useColorScheme();
  return (
    <ThemedView
      style={[styles.booting, { backgroundColor: colors.background }]}
    >
      <Host
        style={{ width: 64, height: 64, backgroundColor: "transparent" }}
        seedColor={SEED}
        colorScheme={scheme}
      >
        <Surface
          color={colors.secondaryContainer}
          modifiers={[size(64, 64)]}
          shape={Shape.RoundedCorner({
            cornerRadii: {
              bottomEnd: 32,
              topStart: 32, 
              bottomStart: 32,
              topEnd: 32,
            },
          })}
        >
          <Box contentAlignment="center" modifiers={[fillMaxSize()]}>
            <LoadingIndicator color={colors.primary} />
          </Box>
        </Surface>
      </Host>
      <ThemedText type="default" themeColor="textSecondary">
        Connecting to Mac...
      </ThemedText>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  booting: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    gap: Spacing.three,
  },
});
