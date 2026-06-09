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
            {mode === 'pair' ? 'Mac’e Bağla' : 'Yeniden Bağlan'}
          </ThemedText>
          <ThemedText type="default" themeColor="textSecondary" style={styles.subtitle}>
            {mode === 'pair'
              ? 'Kurulum tek seferlik. Eşleştirme kodunu gir, gerisini biz hallederiz.'
              : 'Kablosuz hata ayıklamayı tekrar aç; bağlantı otomatik kurulacak.'}
          </ThemedText>
        </View>

        <ThemedView type="backgroundElement" style={styles.card}>
          {mode === 'pair' ? (
            <>
              <Step n={1} text="Kablosuz hata ayıklamayı aç" />
              <Step n={2} text="“Eşleştirme kodu ile cihaz eşleştir”e dokun" />
              <Step n={3} text="6 haneli kodu aşağıya gir" />

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
            <Step n={1} text="Geliştirici ayarlarından kablosuz hata ayıklamayı aç" />
          )}

          <Pressable onPress={openSettings} style={styles.linkBtn} disabled={busy}>
            <ThemedText type="linkPrimary">Geliştirici Ayarlarını Aç</ThemedText>
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
              {mode === 'pair' ? 'Eşleştir' : 'Tekrar Dene'}
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
