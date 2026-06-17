import { CameraView, useCameraPermissions } from 'expo-camera';
import type { ReactNode } from 'react';
import { useRef } from 'react';
import { Button, Pressable, StyleSheet, Text } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';

import { parsePairingQR, type PairingScan } from './pairing-store';

/** Full-screen QR scanner that resolves a valid pairing (+ optional server config) from the Mac's QR. */
export function PairScanner({
  onPaired,
  onCancel,
}: {
  onPaired: (scan: PairingScan) => void;
  onCancel: () => void;
}) {
  const [permission, requestPermission] = useCameraPermissions();
  const handled = useRef(false);

  if (!permission) {
    return (
      <Centered>
        <ThemedText type="small" themeColor="textSecondary">
          Camera is preparing…
        </ThemedText>
      </Centered>
    );
  }

  if (!permission.granted) {
    return (
      <Centered>
        <ThemedText type="smallBold">Camera permission required</ThemedText>
        <ThemedText type="small" themeColor="textSecondary" style={styles.hint}>
          QR code scanning requires camera access.
        </ThemedText>
        <Pressable onPress={requestPermission} className='bg-blue-500 w-full py-3 rounded-full items-center'>
          <Text className='text-white'>Grant Permission</Text>
        </Pressable>
        <Pressable onPress={onCancel} className='bg-gray-500 w-full py-3 rounded-full items-center'>
          <Text className='text-white'>Cancel</Text>
        </Pressable>

      </Centered>
    );
  }

  return (
    <ThemedView style={styles.root}>
      <CameraView
        style={styles.camera}
        facing="back"
        barcodeScannerSettings={{ barcodeTypes: ['qr'] }}
        onBarcodeScanned={({ data }) => {
          if (handled.current) return;
          const scan = parsePairingQR(data);
          if (!scan) return; // ignore non-pairing QR codes
          handled.current = true;
          onPaired(scan);
        }}
      />
      <SafeAreaView edges={['bottom']} style={styles.footer}>
        <ThemedText type="small" themeColor="textSecondary" style={styles.hint}>
          Show the “Pairing QR” screen on your Mac to pair.
        </ThemedText>
        <Pressable onPress={onCancel} className='bg-blue-500 w-full py-3 rounded-full items-center'>
          <Text className='text-white'>Cancel</Text>
        </Pressable>
      </SafeAreaView>
    </ThemedView>
  );
}

function Centered({ children }: { children: ReactNode }) {
  return (
    <ThemedView style={styles.root}>
      <SafeAreaView style={styles.centered}>{children}</SafeAreaView>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  camera: { flex: 1 },
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: Spacing.three,
    padding: Spacing.four,
  },
  footer: { padding: Spacing.four, gap: Spacing.two },
  hint: { textAlign: 'center' },
});
