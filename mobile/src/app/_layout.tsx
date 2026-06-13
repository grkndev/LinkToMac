import { DarkTheme, DefaultTheme, Stack, ThemeProvider } from 'expo-router';
import { ActivityIndicator, StyleSheet, useColorScheme } from 'react-native';

import { AnimatedSplashOverlay } from '@/components/animated-icon';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';
import { PairingProvider, usePairing } from '@/features/relay/pairing-context';
import { useRelayAutostart } from '@/features/relay/use-relay-autostart';
import { ClipBootProvider, useClipBootContext } from '@/features/selfadb/clip-boot-context';
import {StatusBar} from "expo-status-bar"

export default function RootLayout() {
  const colorScheme = useColorScheme();

  return (
    <ThemeProvider value={colorScheme === 'dark' ? DarkTheme : DefaultTheme}>
      <ClipBootProvider>
        <PairingProvider>
          <StatusBar style='auto' />
          <AnimatedSplashOverlay />
          <RootNavigator />
        </PairingProvider>
      </ClipBootProvider>
    </ThemeProvider>
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
function RootNavigator() {
  const boot = useClipBootContext();
  const { pairing } = usePairing();
  useRelayAutostart();

  // Hold the Stack until boot + SecureStore settle so the guards don't flicker.
  if (boot.state === 'booting' || pairing === undefined) return <Booting />;

  const adbReady = boot.state === 'ready';
  const macPaired = pairing != null;

  return (
    <Stack screenOptions={{ headerShown: false }}>
      <Stack.Protected guard={!adbReady}>
        <Stack.Screen name="adb-setup" />
      </Stack.Protected>
      <Stack.Protected guard={adbReady}>
        <Stack.Protected guard={!macPaired}>
          <Stack.Screen name="pair-mac" />
        </Stack.Protected>
        <Stack.Protected guard={macPaired}>
          <Stack.Screen name="index" />
          <Stack.Screen name="settings" options={{ headerShown: true, title: 'Settings', headerShadowVisible:false }} />
          <Stack.Screen name="logs" options={{ headerShown: true, title: 'Logs' }} />
        </Stack.Protected>
        <Stack.Screen name="qr-scan" options={{ presentation: 'modal' }} />
      </Stack.Protected>
    </Stack>
  );
}

function Booting() {
  return (
    <ThemedView style={styles.booting}>
      <ActivityIndicator />
      <ThemedText type="small" themeColor="textSecondary">
        Bağlanılıyor…
      </ThemedText>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  booting: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: Spacing.three,
  },
});
