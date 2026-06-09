import type { ReactNode } from 'react';
import { useEffect, useState } from 'react';
import { Button, StyleSheet } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';
import SelfAdb from '@/features/selfadb/client';
import { PairScanner } from '@/features/relay/pair-scanner';
import { loadPairing, savePairing, type Pairing } from '@/features/relay/pairing-store';
import { RELAY_TOKEN, relayUrl } from '@/features/relay/relay-config';

type RelayUi = { status: string; peerOnline: boolean; lastError?: string | null };

/**
 * Status + control for the relay, which now runs natively inside the foreground service
 * (survives the app being backgrounded/closed). This screen only configures it (pushes
 * url/token/room) and reflects its state; it does not own the connection.
 */
export default function RelayScreen() {
  const [pairing, setPairing] = useState<Pairing | null | undefined>(undefined);
  const [scanning, setScanning] = useState(false);
  const [relay, setRelay] = useState<RelayUi>({ status: 'disconnected', peerOnline: false });
  const [lastCopied, setLastCopied] = useState<string | null>(null);
  const [paused, setPaused] = useState(false);
  const [batteryOk, setBatteryOk] = useState<boolean | null>(null);

  useEffect(() => {
    loadPairing().then(setPairing);
    SelfAdb.hasIgnoreBatteryOptimizations().then(setBatteryOk).catch(() => setBatteryOk(null));
  }, []);

  // Push relay config to native whenever we have a pairing (refreshes the dev IP each launch).
  useEffect(() => {
    if (!pairing) return;
    SelfAdb.setRelay(relayUrl(), RELAY_TOKEN, pairing.room).catch(() => {});
  }, [pairing]);

  // Mirror native relay status + local clipboard copies for display.
  useEffect(() => {
    const r = SelfAdb.addListener('onRelay', (e) =>
      setRelay({ status: e.status, peerOnline: e.peerOnline, lastError: e.lastError }),
    );
    const c = SelfAdb.addListener('onClip', (e) => setLastCopied(e.text));
    return () => {
      r.remove();
      c.remove();
    };
  }, []);

  if (pairing === undefined) {
    return (
      <Screen>
        <ThemedText type="small" themeColor="textSecondary">
          Yükleniyor…
        </ThemedText>
      </Screen>
    );
  }

  if (scanning) {
    return (
      <PairScanner
        onPaired={async (next) => {
          await savePairing(next);
          setPairing(next);
          setScanning(false);
        }}
        onCancel={() => setScanning(false)}
      />
    );
  }

  const togglePause = () => {
    const next = !paused;
    setPaused(next);
    SelfAdb.relaySetPaused(next).catch(() => {});
  };

  return (
    <Screen>
      <ThemedText type="subtitle">Relay</ThemedText>

      {pairing ? (
        <>
          <ThemedView type="backgroundElement" style={styles.card}>
            <Row label="Durum" value={paused ? 'duraklatıldı' : relay.status} />
            <Row label="Mac" value={relay.peerOnline ? 'online' : 'offline'} />
            <Row label="Oda" value={`${pairing.room.slice(0, 10)}…`} />
            {lastCopied ? <Row label="Son kopya" value={truncate(lastCopied)} /> : null}
            {relay.lastError ? <Row label="Hata" value={relay.lastError} /> : null}
          </ThemedView>

          {batteryOk === false ? (
            <Button
              title="Pil iznini ver (arka planda çalışsın)"
              onPress={async () => {
                await SelfAdb.requestIgnoreBatteryOptimizations().catch(() => {});
              }}
            />
          ) : null}
          <Button title={paused ? 'Devam' : 'Duraklat'} onPress={togglePause} />
          <Button title="Yeniden eşleştir (QR tara)" onPress={() => setScanning(true)} />
        </>
      ) : (
        <ThemedView type="backgroundElement" style={styles.card}>
          <ThemedText type="smallBold">Henüz eşleştirilmedi</ThemedText>
          <ThemedText type="small" themeColor="textSecondary">
            Mac uygulamasında menüden “Pairing QR…” aç, sonra aşağıdaki butonla okut.
          </ThemedText>
          <Button title="QR Tara" onPress={() => setScanning(true)} />
        </ThemedView>
      )}
    </Screen>
  );
}

function truncate(s: string): string {
  return s.length > 24 ? `${s.slice(0, 24)}…` : s;
}

function Screen({ children }: { children: ReactNode }) {
  return (
    <ThemedView style={styles.root}>
      <SafeAreaView style={styles.safe}>{children}</SafeAreaView>
    </ThemedView>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <ThemedView type="backgroundElement" style={styles.row}>
      <ThemedText type="smallBold" themeColor="textSecondary">
        {label}
      </ThemedText>
      <ThemedText type="small" style={styles.value}>
        {value}
      </ThemedText>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  safe: { flex: 1, padding: Spacing.four, gap: Spacing.three },
  card: {
    borderRadius: Spacing.three,
    padding: Spacing.three,
    gap: Spacing.two,
  },
  row: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    gap: Spacing.three,
  },
  value: { flexShrink: 1, textAlign: 'right' },
});
