import { useRouter } from 'expo-router';
import { Pressable, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';

/** Mac pairing entry: shown when ADB is ready but no Mac has been paired yet. */
export default function PairMacScreen() {
  const theme = useTheme();
  const router = useRouter();

  return (
    <ThemedView style={styles.root}>
      <SafeAreaView style={styles.safe}>
        <View style={styles.hero}>
          <ThemedText type="title" style={styles.title}>
            Cihazınızı eşleştirin
          </ThemedText>
          <ThemedText type="default" themeColor="textSecondary">
            Panonu Mac ile senkronize etmek için cihazları eşleştir.
          </ThemedText>
        </View>

        <ThemedView type="backgroundElement" style={styles.card}>
          <Step n={1} text="Mac uygulamasında menüden “Pairing QR…” penceresini aç" />
          <Step n={2} text="QR kodu telefonunla tara" />
        </ThemedView>

        <Pressable
          onPress={() => router.push('/qr-scan')}
          style={[styles.primaryBtn, { backgroundColor: theme.text }]}>
          <ThemedText type="default" style={[styles.primaryLabel, { color: theme.background }]}>
            QR Kodu Tara
          </ThemedText>
        </Pressable>
      </SafeAreaView>
    </ThemedView>
  );
}

function Step({ n, text }: { n: number; text: string }) {
  return (
    <View style={styles.step}>
      <ThemedText type="smallBold" themeColor="textSecondary">
        {n}.
      </ThemedText>
      <ThemedText type="small" style={styles.stepText}>
        {text}
      </ThemedText>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  safe: {
    flex: 1,
    paddingHorizontal: Spacing.four,
    justifyContent: 'center',
    gap: Spacing.five,
  },
  hero: { gap: Spacing.three },
  title: { fontSize: 40, lineHeight: 44 },
  card: {
    borderRadius: Spacing.four,
    padding: Spacing.four,
    gap: Spacing.three,
  },
  step: { flexDirection: 'row', gap: Spacing.two, alignItems: 'flex-start' },
  stepText: { flex: 1 },
  primaryBtn: {
    borderRadius: Spacing.three,
    paddingVertical: Spacing.three,
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 52,
  },
  primaryLabel: { fontWeight: '700' },
});
