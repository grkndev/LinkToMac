import { DarkTheme, DefaultTheme, ThemeProvider } from 'expo-router';
import { ActivityIndicator, StyleSheet, useColorScheme } from 'react-native';

import { AnimatedSplashOverlay } from '@/components/animated-icon';
import AppTabs from '@/components/app-tabs';
import { PairScreen } from '@/components/PairScreen';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';
import { useClipBoot } from '@/features/selfadb/use-clip-boot';
import { useRelayAutostart } from '@/features/relay/use-relay-autostart';

export default function RootLayout() {
  const colorScheme = useColorScheme();
  const boot = useClipBoot();
  useRelayAutostart();

  return (
    <ThemeProvider value={colorScheme === 'dark' ? DarkTheme : DefaultTheme}>
      <AnimatedSplashOverlay />
      {boot.state === 'ready' ? (
        <AppTabs />
      ) : boot.state === 'booting' ? (
        <Booting />
      ) : (
        <PairScreen boot={boot} />
      )}
    </ThemeProvider>
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
