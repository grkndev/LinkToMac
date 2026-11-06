import {
  Box,
  Button,
  Column,
  Icon,
  Row,
  Shape,
  Surface,
  // Inline spans must be the library Text (see components/text.tsx); the wrapper styles them.
  Text as SpanText,
  type MaterialColors,
} from '@expo/ui/jetpack-compose';
import { Text } from "@/components/text";
import {
  background,
  fillMaxSize,
  fillMaxWidth,
  height,
  offset,
  padding,
  rotate,
  size,
  verticalScroll,
  weight,
} from '@expo/ui/jetpack-compose/modifiers';
import type { ReactNode } from 'react';
import { useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useIcons } from '@/components/icons';
import { useM3Colors } from '@/components/m3';
import { M3Host } from '@/components/m3-screen';
import { Spacing } from '@/constants/theme';

const radius = (r: number) =>
  Shape.RoundedCorner({ cornerRadii: { topStart: r, topEnd: r, bottomStart: r, bottomEnd: r } });

/** Mac pairing entry: shown until a Mac has been paired. Pairing is the app's only gate. */
export default function PairMacScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const colors = useM3Colors();
  const icons = useIcons();

  return (
    <M3Host>
      <Column
        modifiers={[
          fillMaxSize(),
          padding(Spacing.three + 4, insets.top + Spacing.four, Spacing.three + 4, insets.bottom + Spacing.three + 4),
        ]}
      >
        {/* Scrolls on short screens; the CTA below stays pinned. */}
        <Column modifiers={[fillMaxWidth(), weight(1), verticalScroll()]}>
          {/* Hero: phone — link — laptop. Drawn in one Box (later children on top) so the link
              badge overlaps both devices; its background-coloured ring makes it read as a clasp. */}
          <Box
            contentAlignment="center"
            modifiers={[fillMaxWidth(), height(124 + 84), padding(0, 40, 0, 44)]}
          >
            <Box modifiers={[offset(-60, 0)]}>
              <Surface
                color={colors.tertiaryContainer}
                shape={radius(36)}
                modifiers={[size(104, 104), rotate(-6)]}
              >
                <Box contentAlignment="center" modifiers={[size(104, 104)]}>
                  <Icon source={icons.smartphone} size={52} tint={colors.onTertiaryContainer} />
                </Box>
              </Surface>
            </Box>
            <Box modifiers={[offset(62, 0)]}>
              <Surface color={colors.primaryContainer} shape={radius(60)} modifiers={[size(120, 120)]}>
                <Box contentAlignment="center" modifiers={[size(120, 120)]}>
                  <Icon source={icons.laptop} size={60} tint={colors.onPrimaryContainer} />
                </Box>
              </Surface>
            </Box>
            <Surface color={colors.background} shape={radius(28)} modifiers={[size(56, 56)]}>
              <Box contentAlignment="center" modifiers={[size(56, 56)]}>
                <Surface color={colors.primary} shape={radius(22)} modifiers={[size(44, 44)]}>
                  <Box contentAlignment="center" modifiers={[size(44, 44)]}>
                    <Icon source={icons.link} size={24} tint={colors.onPrimary} />
                  </Box>
                </Surface>
              </Box>
            </Surface>
          </Box>

          <Column
            modifiers={[fillMaxWidth(), padding(Spacing.one, 0, Spacing.one, 0)]}
            verticalArrangement={{ spacedBy: 10 }}
          >
            <Text
              color={colors.onBackground}
              style={{ typography: 'headlineLarge', fontSize: 34, lineHeight: 40, fontWeight: '600' }}
            >
              Pair your device
            </Text>
            <Text color={colors.onSurfaceVariant} style={{ typography: 'bodyLarge' }}>
              Pair with your Mac to sync your clipboard between devices.
            </Text>
          </Column>

          <Box modifiers={[height(28)]} />

          {/* Steps — one tonal card, numbered primary bubbles, hairline between. */}
          <Column
            modifiers={[fillMaxWidth(), padding(Spacing.two, Spacing.two, Spacing.two, Spacing.two)]}
          >
            <Surface color={colors.surfaceContainer} shape={radius(28)} modifiers={[fillMaxWidth()]}>
              <Column modifiers={[fillMaxWidth(), padding(Spacing.two, Spacing.two, Spacing.two, Spacing.two)]}>
                <Step colors={colors} n={1}>
                  <Text color={colors.onSurface} style={{ typography: 'bodyLarge' }}>
                    On your Mac, open{' '}
                    <SpanText style={{ fontWeight: '600' }}>Pairing QR…</SpanText>
                    {' '}from the Link to Mac menu.
                  </Text>
                </Step>
                <Box modifiers={[fillMaxWidth(), padding(60, 0, 12, 0)]}>
                  <Box modifiers={[fillMaxWidth(), height(1), background(colors.outlineVariant)]} />
                </Box>
                <Step colors={colors} n={2}>
                  <Text color={colors.onSurface} style={{ typography: 'bodyLarge' }}>
                    Scan the QR code with this phone.
                  </Text>
                </Step>
              </Column>
            </Surface>
          </Column>
        </Column>

        <Button
          onClick={() => router.push('/qr-scan')}
          modifiers={[fillMaxWidth()]}
          contentPadding={{ top: 16, bottom: 16 }}
        >
          <Row horizontalArrangement={{ spacedBy: 10 }} verticalAlignment="center">
            <Icon source={icons.qr} size={22} tint={colors.onPrimary} />
            <Text color={colors.onPrimary} style={{ typography: 'labelLarge', fontSize: 16, fontWeight: '500' }}>
              Scan QR code
            </Text>
          </Row>
        </Button>
      </Column>
    </M3Host>
  );
}

/** Numbered primary bubble + wrapping instruction — the M3 Expressive list idiom. */
function Step({ colors, n, children }: { colors: MaterialColors; n: number; children: ReactNode }) {
  return (
    <Row
      modifiers={[fillMaxWidth(), padding(12, 14, 12, 14)]}
      horizontalArrangement={{ spacedBy: Spacing.three }}
      verticalAlignment="center"
    >
      <Surface color={colors.primary} shape={radius(16)} modifiers={[size(32, 32)]}>
        <Box contentAlignment="center" modifiers={[size(32, 32)]}>
          <Text color={colors.onPrimary} style={{ typography: 'labelLarge', fontWeight: '600' }}>
            {n}
          </Text>
        </Box>
      </Surface>
      <Column modifiers={[weight(1)]}>{children}</Column>
    </Row>
  );
}
