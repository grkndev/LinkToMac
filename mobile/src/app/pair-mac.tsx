import {
  Box,
  Button,
  Column,
  Host,
  Row,
  Text,
  useMaterialColors,
  type MaterialColors,
} from '@expo/ui/jetpack-compose';
import {
  background,
  clip,
  fillMaxSize,
  fillMaxWidth,
  padding,
  paddingAll,
  Shapes,
  size,
  weight,
} from '@expo/ui/jetpack-compose/modifiers';
import { useRouter } from 'expo-router';
import { useColorScheme } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Spacing } from '@/constants/theme';

/** Brand blue (app.json notification color) — seeds the Material 3 palette. Matches Settings. */
const SEED = '#208AEF';

/** Mac pairing entry: shown when ADB is ready but no Mac has been paired yet. */
export default function PairMacScreen() {
  const router = useRouter();
  const scheme = useColorScheme();
  const insets = useSafeAreaInsets();
  const colors = useMaterialColors({ seedColor: SEED });

  return (
    <Host style={{ flex: 1, backgroundColor: colors.background }} seedColor={SEED} colorScheme={scheme}>
      {/* Outer column fills the screen and centers the content group vertically. */}
      <Column
        modifiers={[
          fillMaxSize(),
          padding(Spacing.four, insets.top + Spacing.four, Spacing.four, insets.bottom + Spacing.four),
        ]}
        verticalArrangement="center"
      >
        <Column modifiers={[fillMaxWidth()]} verticalArrangement={{ spacedBy: Spacing.five }}>
          {/* Hero */}
          <Column modifiers={[fillMaxWidth()]} verticalArrangement={{ spacedBy: Spacing.three }}>
            <Text color={colors.onBackground} style={{ typography: 'displaySmall', fontWeight: '700' }}>
              Cihazınızı eşleştirin
            </Text>
            <Text color={colors.onSurfaceVariant} style={{ typography: 'bodyLarge' }}>
              Panonu Mac ile senkronize etmek için cihazları eşleştir.
            </Text>
          </Column>

          {/* Steps — tonal extra-large rounded container, matching Settings' sections. */}
          <Column
            modifiers={[
              fillMaxWidth(),
              clip(Shapes.RoundedCorner(28)),
              background(colors.surfaceContainerHigh),
              paddingAll(Spacing.four),
            ]}
            verticalArrangement={{ spacedBy: Spacing.three }}
          >
            <Step colors={colors} n={1} text="Mac uygulamasında menüden “Pairing QR…” penceresini aç" />
            <Step colors={colors} n={2} text="QR kodu telefonunla tara" />
          </Column>

          {/* Primary CTA — native M3 filled button (uses the seeded primary/onPrimary pair). */}
          <Button
            onClick={() => router.push('/qr-scan')}
            modifiers={[fillMaxWidth()]}
            contentPadding={{ top: Spacing.two, bottom: Spacing.two }}
          >
            <Text color={colors.onPrimary} style={{ typography: 'labelLarge', fontWeight: '600' }}>
              QR Kodu Tara
            </Text>
          </Button>
        </Column>
      </Column>
    </Host>
  );
}

/** Numbered tonal bubble + wrapping instruction text — the M3 Expressive list idiom. */
function Step({ colors, n, text }: { colors: MaterialColors; n: number; text: string }) {
  return (
    <Row
      modifiers={[fillMaxWidth()]}
      horizontalArrangement={{ spacedBy: Spacing.three }}
      verticalAlignment="center"
    >
      <Box
        contentAlignment="center"
        modifiers={[size(28, 28), clip(Shapes.Circle), background(colors.primaryContainer)]}
      >
        <Text color={colors.onPrimaryContainer} style={{ typography: 'labelLarge', fontWeight: '700' }}>
          {n}
        </Text>
      </Box>
      <Text modifiers={[weight(1)]} color={colors.onSurface} style={{ typography: 'bodyMedium' }}>
        {text}
      </Text>
    </Row>
  );
}
