import {
  Box,
  Button,
  Column,
  Host,
  Icon,
  LoadingIndicator,
  Row,
  Shape,
  Surface,
  } from '@expo/ui/jetpack-compose';
import { Text } from "@/components/text";
import {
  fillMaxSize,
  fillMaxWidth,
  height,
  padding,
  size,
  weight,
} from '@expo/ui/jetpack-compose/modifiers';
import { CameraView, useCameraPermissions } from 'expo-camera';
import { useRef, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { PrimaryButton } from '@/components/buttons';
import { useIcons } from '@/components/icons';
import { useHostTheme, useM3Colors } from '@/components/m3';
import { M3Host } from '@/components/m3-screen';
import { Spacing } from '@/constants/theme';

import { parsePairingQR, type PairingScan } from './pairing-store';

const radius = (r: number) =>
  Shape.RoundedCorner({ cornerRadii: { topStart: r, topEnd: r, bottomStart: r, bottomEnd: r } });

// The viewfinder sits over a live camera feed, so its palette is fixed (not themed): white
// brackets, translucent controls, a dark scrim card.
const SCRIM = '#1E1F23E0';
const CONTROL = '#FFFFFF24';
const ON_DARK = '#F4F4F6';
const FRAME = 256;

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
  const [torch, setTorch] = useState(false);
  const colors = useM3Colors();
  const icons = useIcons();
  const hostTheme = useHostTheme();
  const insets = useSafeAreaInsets();

  if (!permission) {
    return (
      <M3Host>
        <Box contentAlignment="center" modifiers={[fillMaxSize()]}>
          <LoadingIndicator color={colors.primary} />
        </Box>
      </M3Host>
    );
  }

  if (!permission.granted) {
    return (
      <M3Host>
        <Column
          modifiers={[
            fillMaxSize(),
            padding(Spacing.three + 4, insets.top + Spacing.three, Spacing.three + 4, insets.bottom + Spacing.three),
          ]}
        >
          <Column
            modifiers={[fillMaxWidth(), weight(1)]}
            horizontalAlignment="center"
            verticalArrangement="center"
          >
            <Column
              horizontalAlignment="center"
              verticalArrangement={{ spacedBy: Spacing.three }}
              modifiers={[padding(12, 0, 12, 0)]}
            >
              <Surface color={colors.primaryContainer} shape={radius(36)} modifiers={[size(104, 104)]}>
                <Box contentAlignment="center" modifiers={[size(104, 104)]}>
                  <Icon source={icons.photoCamera} size={52} tint={colors.onPrimaryContainer} />
                </Box>
              </Surface>
              <Box modifiers={[padding(0, Spacing.two, 0, 0)]}>
                <Text
                  color={colors.onSurface}
                  style={{ typography: 'headlineSmall', fontSize: 28, lineHeight: 34, fontWeight: '600', textAlign: 'center' }}
                >
                  Camera permission required
                </Text>
              </Box>
              <Text color={colors.onSurfaceVariant} style={{ typography: 'bodyLarge', textAlign: 'center' }}>
                QR code scanning requires camera access.
              </Text>
            </Column>
          </Column>
          <Column verticalArrangement={{ spacedBy: Spacing.two }} modifiers={[fillMaxWidth()]}>
            <PrimaryButton colors={colors} label="Grant permission" onPress={requestPermission} />
            <Button
              onClick={onCancel}
              colors={{ containerColor: 'transparent', contentColor: colors.primary }}
              modifiers={[fillMaxWidth()]}
              contentPadding={{ top: 16, bottom: 16 }}
            >
              <Text color={colors.primary} style={{ typography: 'labelLarge', fontSize: 16, fontWeight: '500' }}>
                Cancel
              </Text>
            </Button>
          </Column>
        </Column>
      </M3Host>
    );
  }

  return (
    <View style={styles.root}>
      <CameraView
        style={StyleSheet.absoluteFill}
        facing="back"
        enableTorch={torch}
        barcodeScannerSettings={{ barcodeTypes: ['qr'] }}
        onBarcodeScanned={({ data }) => {
          if (handled.current) return;
          const scan = parsePairingQR(data);
          if (!scan) return; // ignore non-pairing QR codes
          handled.current = true;
          onPaired(scan);
        }}
      />

      {/* The one non-Compose piece: Compose has no per-side border, so the four corner brackets
          are plain Views, centred over the feed. */}
      <View pointerEvents="none" style={styles.frameWrap}>
        <View style={styles.frame}>
          <View style={[styles.corner, styles.tl]} />
          <View style={[styles.corner, styles.tr]} />
          <View style={[styles.corner, styles.bl]} />
          <View style={[styles.corner, styles.br]} />
        </View>
      </View>

      {/* Transparent Compose layer: top controls + the instruction card. */}
      <Host style={StyleSheet.absoluteFill} {...hostTheme}>
        <Column
          modifiers={[
            fillMaxSize(),
            padding(Spacing.three, insets.top + Spacing.one, Spacing.three, insets.bottom + Spacing.three),
          ]}
        >
          <Row modifiers={[fillMaxWidth(), height(56)]} horizontalArrangement={{ spacedBy: 12 }} verticalAlignment="center">
            <Surface color={CONTROL} shape={radius(24)} onClick={onCancel} modifiers={[size(48, 48)]}>
              <Box contentAlignment="center" modifiers={[size(48, 48)]}>
                <Icon source={icons.close} size={24} tint={ON_DARK} />
              </Box>
            </Surface>
            <Text modifiers={[weight(1)]} color={ON_DARK} style={{ typography: 'titleLarge', fontSize: 20, fontWeight: '500' }}>
              Scan pairing code
            </Text>
            <Surface
              color={torch ? ON_DARK : CONTROL}
              shape={radius(24)}
              onClick={() => setTorch((v) => !v)}
              modifiers={[size(48, 48)]}
            >
              <Box contentAlignment="center" modifiers={[size(48, 48)]}>
                <Icon source={icons.flashlight} size={24} tint={torch ? '#1E1F23FF' : ON_DARK} />
              </Box>
            </Surface>
          </Row>

          <Box modifiers={[weight(1)]} />

          <Surface color={SCRIM} shape={radius(28)} modifiers={[fillMaxWidth()]}>
            <Column modifiers={[fillMaxWidth(), padding(20, 20, 20, 20)]} verticalArrangement={{ spacedBy: Spacing.three }}>
              <Row horizontalArrangement={{ spacedBy: 14 }} verticalAlignment="top">
                <Icon source={icons.laptop} size={24} tint={ON_DARK} />
                <Text modifiers={[weight(1)]} color={ON_DARK} style={{ typography: 'bodyLarge', fontSize: 15 }}>
                  Show the “Pairing QR” screen on your Mac to pair.
                </Text>
              </Row>
              <Button
                onClick={onCancel}
                colors={{ containerColor: CONTROL, contentColor: ON_DARK }}
                modifiers={[fillMaxWidth()]}
                contentPadding={{ top: 12, bottom: 12 }}
              >
                <Text color={ON_DARK} style={{ typography: 'labelLarge', fontSize: 15, fontWeight: '500' }}>
                  Cancel
                </Text>
              </Button>
            </Column>
          </Surface>
        </Column>
      </Host>
    </View>
  );
}

const BRACKET = 52;
const STROKE = 5;
const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#0C0D10' },
  frameWrap: { ...StyleSheet.absoluteFill, alignItems: 'center', justifyContent: 'center' },
  frame: { width: FRAME, height: FRAME },
  corner: { position: 'absolute', width: BRACKET, height: BRACKET, borderColor: '#FFFFFF' },
  tl: { left: 0, top: 0, borderLeftWidth: STROKE, borderTopWidth: STROKE, borderTopLeftRadius: 32 },
  tr: { right: 0, top: 0, borderRightWidth: STROKE, borderTopWidth: STROKE, borderTopRightRadius: 32 },
  bl: { left: 0, bottom: 0, borderLeftWidth: STROKE, borderBottomWidth: STROKE, borderBottomLeftRadius: 32 },
  br: { right: 0, bottom: 0, borderRightWidth: STROKE, borderBottomWidth: STROKE, borderBottomRightRadius: 32 },
});
