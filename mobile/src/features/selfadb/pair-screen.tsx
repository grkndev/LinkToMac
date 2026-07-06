import { useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, TextInput, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import SelfAdb from '@/features/selfadb/client';
import type { ClipBoot } from '@/features/selfadb/use-clip-boot';

const CODE_LENGTH = 6;

/**
 * First-run / reconnect gate. Shown by the root layout whenever the pipeline
 * isn't running yet. Two modes derived from the boot state:
 *   - pair:      never paired -> collect the 6-digit code, then pairAuto()
 *   - reconnect: paired but wireless debugging is off and we can't self-enable
 *                it yet -> ask the user to turn it back on, then retry
 */
export function PairScreen({ boot }: { boot: ClipBoot }) {
  const theme = useTheme();
  const [code, setCode] = useState('');

  const busy = boot.state === 'pairing';
  const mode = boot.state === 'need-pair' || boot.state === 'pairing' ? 'pair' : 'reconnect';
  const canSubmit = code.length === CODE_LENGTH && !busy;

  const openSettings = () => {
    SelfAdb.openWirelessDebuggingSettings().catch(() => {});
  };

  return (
    <ThemedView style={styles.root}>
      <SafeAreaView style={styles.safe}>
        <View style={styles.hero}>
          <ThemedText type="title" style={styles.title}>
            {mode === 'pair' ? 'Connect to Mac' : 'Reconnect'}
          </ThemedText>
          <ThemedText type="default" themeColor="textSecondary" style={styles.subtitle}>
            {mode === 'pair'
              ? 'Setup is a one-time thing. Enter the pairing code and we’ll handle the rest.'
              : 'Turn Wireless debugging back on and the connection will be restored automatically.'}
          </ThemedText>
        </View>

        <ThemedView type="backgroundElement" style={styles.card}>
          {mode === 'pair' ? (
            <>
              <Step n={1} text="Turn on Wireless debugging" />
              <Step n={2} text="Tap “Pair device with pairing code”" />
              <Step n={3} text="Enter the 6-digit code below" />

              <TextInput
                style={[
                  styles.input,
                  { color: theme.text, backgroundColor: theme.backgroundSelected },
                ]}
                value={code}
                onChangeText={(t) => setCode(t.replace(/\D/g, '').slice(0, CODE_LENGTH))}
                placeholder="000000"
                placeholderTextColor={theme.textSecondary}
                keyboardType="number-pad"
                maxLength={CODE_LENGTH}
                editable={!busy}
                textAlign="center"
              />
            </>
          ) : (
            <Step n={1} text="Turn on Wireless debugging in Developer options" />
          )}

          <Pressable onPress={openSettings} style={styles.linkBtn} disabled={busy}>
            <ThemedText type="linkPrimary">Open Developer Settings</ThemedText>
          </Pressable>
        </ThemedView>

        {boot.error ? (
          <ThemedText type="small" style={[styles.error, { color: '#e5484d' }]}>
            {boot.error}
          </ThemedText>
        ) : null}

        <Pressable
          onPress={() => (mode === 'pair' ? boot.pair(code) : boot.refresh())}
          disabled={mode === 'pair' ? !canSubmit : busy}
          style={[
            styles.primaryBtn,
            { backgroundColor: theme.text },
            (mode === 'pair' ? !canSubmit : busy) && styles.primaryBtnDisabled,
          ]}>
          {busy ? (
            <ActivityIndicator color={theme.background} />
          ) : (
            <ThemedText type="default" style={[styles.primaryLabel, { color: theme.background }]}>
              {mode === 'pair' ? 'Pair' : 'Try Again'}
            </ThemedText>
          )}
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
  subtitle: {},
  card: {
    borderRadius: Spacing.four,
    padding: Spacing.four,
    gap: Spacing.three,
  },
  step: { flexDirection: 'row', gap: Spacing.two, alignItems: 'flex-start' },
  stepText: { flex: 1 },
  input: {
    marginTop: Spacing.two,
    borderRadius: Spacing.three,
    paddingVertical: Spacing.three,
    fontSize: 28,
    letterSpacing: 8,
    fontWeight: '700',
  },
  linkBtn: { paddingTop: Spacing.one },
  error: { textAlign: 'center' },
  primaryBtn: {
    borderRadius: Spacing.three,
    paddingVertical: Spacing.three,
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 52,
  },
  primaryBtnDisabled: { opacity: 0.4 },
  primaryLabel: { fontWeight: '700' },
});
