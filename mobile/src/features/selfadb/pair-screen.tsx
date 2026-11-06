import {
  Box,
  Column,
  Icon,
  OutlinedTextField,
  Row,
  Shape,
  Surface,
  useNativeState,
  type MaterialColors,
  type TextFieldRef,
} from '@expo/ui/jetpack-compose';
import { Text } from "@/components/text";
import {
  animated,
  fillMaxSize,
  fillMaxWidth,
  graphicsLayer,
  imePadding,
  padding,
  keyframes,
  size,
  verticalScroll,
  weight,
} from '@expo/ui/jetpack-compose/modifiers';
import { useRef, useState } from 'react';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { LinkButton, PrimaryButton } from '@/components/buttons';
import { useIcons } from '@/components/icons';
import { Group, useM3Colors, withAlpha } from '@/components/m3';
import { M3Host } from '@/components/m3-screen';
import { Reveal, useLatched } from '@/components/motion';
import { GroupRow } from '@/components/rows';
import { Spacing, StatusColors } from '@/constants/theme';
import { MONO } from '@/constants/typography';
import SelfAdb from '@/features/selfadb/client';
import type { ClipBoot } from '@/features/selfadb/use-clip-boot';

const CODE_LENGTH = 6;

const radius = (r: number) =>
  Shape.RoundedCorner({ cornerRadii: { topStart: r, topEnd: r, bottomStart: r, bottomEnd: r } });

/**
 * Setup screen for *automatic* clipboard capture (self-ADB -> shell-UID daemon). Reachable from
 * Settings and from the capture banner; never a gate — see the routing note in app/_layout.tsx.
 * Three modes derived from the capture state:
 *   - live:      the daemon is up, nothing to do
 *   - pair:      never paired -> collect the 6-digit code, then pairAuto()
 *   - reconnect: paired but wireless debugging is off and we can't self-enable
 *                it yet -> ask the user to turn it back on, then retry
 */
export function PairScreen({ boot }: { boot: ClipBoot }) {
  const colors = useM3Colors();
  const icons = useIcons();
  const insets = useSafeAreaInsets();
  const [code, setCode] = useState('');
  const codeText = useNativeState('');
  const codeRef = useRef<TextFieldRef>(null);

  const mode =
    boot.state === 'live'
      ? 'live'
      : boot.state === 'pairing' || boot.reason === 'never-paired'
        ? 'pair'
        : 'reconnect';
  // In reconnect mode, `boot.refreshing` covers both the initial auto-retry-on-foreground
  // and a manual Try Again tap — without it the button looked dead for its whole in-flight
  // window (up to 20s) with zero feedback (issue #30).
  const busy = boot.state === 'pairing' || (mode === 'reconnect' && boot.refreshing);
  const canSubmit = code.length === CODE_LENGTH && !busy;

  // Shake the code field each time a pair attempt ENDS in an error (pairing → not pairing with an
  // error set; `pair()` sets both in one batch). Counting the transitions, not watching the error
  // string, so a second identical failure shakes again.
  const [shakes, setShakes] = useState(0);
  const [wasPairing, setWasPairing] = useState(false);
  const isPairing = boot.state === 'pairing';
  if (isPairing !== wasPairing) {
    setWasPairing(isPairing);
    if (wasPairing && boot.error) setShakes((n) => n + 1);
  }
  // The target alternates so every shake is a change (see Motion in motion.tsx); the keyframes
  // swing out and settle regardless of direction.
  const shakeX = animated(
    shakes % 2 ? 0.0001 : 0,
    keyframes({
      durationMillis: 420,
      keyframes: { 0: 0, 70: -12, 140: 10, 210: -8, 280: 6, 350: -3, 420: 0 },
    }),
  );
  const shownError = useLatched(boot.error);

  const openSettings = () => {
    SelfAdb.openWirelessDebuggingSettings().catch(() => {});
  };

  /** Digits only, capped: the number keyboard still offers `-`/`.` on some IMEs. */
  const onCodeChange = (value: string) => {
    const clean = value.replace(/\D/g, '').slice(0, CODE_LENGTH);
    if (clean !== value) codeRef.current?.setText(clean).catch(() => {});
    setCode(clean);
  };

  if (mode === 'live') {
    return (
      <M3Host>
        <Column
          modifiers={[
            fillMaxSize(),
            padding(Spacing.three, Spacing.one, Spacing.three, insets.bottom + Spacing.three),
          ]}
        >
          <Column
            modifiers={[fillMaxWidth(), weight(1)]}
            horizontalAlignment="center"
            verticalArrangement="center"
          >
            <Column
              horizontalAlignment="center"
              verticalArrangement={{ spacedBy: 14 }}
              modifiers={[padding(Spacing.three, 0, Spacing.three, 0)]}
            >
              <Surface
                color={withAlpha(StatusColors.online, 0.18)}
                shape={radius(60)}
                modifiers={[size(120, 120)]}
              >
                <Box contentAlignment="center" modifiers={[size(120, 120)]}>
                  <Icon source={icons.checkCircle} size={64} tint={StatusColors.online} />
                </Box>
              </Surface>
              <Box modifiers={[padding(0, Spacing.two, 0, 0)]}>
                <Text
                  color={colors.onSurface}
                  style={{ typography: 'headlineMedium', fontSize: 30, lineHeight: 36, fontWeight: '600', textAlign: 'center' }}
                >
                  Capture is on
                </Text>
              </Box>
              <Text color={colors.onSurfaceVariant} style={{ typography: 'bodyLarge', textAlign: 'center' }}>
                Anything you copy on this phone reaches your Mac on its own.
              </Text>
            </Column>
          </Column>
          <Surface color={colors.surfaceContainer} shape={radius(24)} modifiers={[fillMaxWidth()]}>
            <Row
              modifiers={[fillMaxWidth(), padding(16, 16, 16, 16)]}
              horizontalArrangement={{ spacedBy: 14 }}
              verticalAlignment="top"
            >
              <Icon source={icons.verifiedUser} size={22} tint={colors.primary} />
              <Text modifiers={[weight(1)]} color={colors.onSurfaceVariant} style={{ typography: 'bodyMedium' }}>
                Everything else — the Mac link, remote lock, battery, notification and message mirroring —
                runs without this and keeps working if it ever drops.
              </Text>
            </Row>
          </Surface>
        </Column>
      </M3Host>
    );
  }

  return (
    <M3Host>
      <Column modifiers={[fillMaxSize(), imePadding()]}>
          <Column
            modifiers={[
              fillMaxWidth(),
              weight(1),
              verticalScroll(),
              padding(Spacing.three, Spacing.two, Spacing.three, Spacing.three),
            ]}
            verticalArrangement={{ spacedBy: Spacing.three }}
          >
            <Row
              modifiers={[fillMaxWidth(), padding(Spacing.one, 0, Spacing.one, Spacing.one)]}
              horizontalArrangement={{ spacedBy: Spacing.three }}
              verticalAlignment="center"
            >
              <Surface color={colors.tertiaryContainer} shape={radius(20)} modifiers={[size(56, 56)]}>
                <Box contentAlignment="center" modifiers={[size(56, 56)]}>
                  <Icon source={icons.pasteGo} size={28} tint={colors.onTertiaryContainer} />
                </Box>
              </Surface>
              <Text
                color={colors.onSurface}
                style={{ typography: 'headlineSmall', fontSize: 28, lineHeight: 34, fontWeight: '600' }}
              >
                {mode === 'pair' ? 'Capture setup' : 'Reconnect'}
              </Text>
            </Row>

            <Text color={colors.onSurfaceVariant} style={{ typography: 'bodyMedium' }}>
              {mode === 'pair'
                ? 'Setup is a one-time thing. Enter the pairing code and we’ll handle the rest.'
                : 'Turn Wireless debugging back on and capture will be restored automatically.'}
            </Text>

            <Group>
              {mode === 'pair' ? (
                <>
                  <Step colors={colors} n={1} text="Turn on Wireless debugging" />
                  <Step colors={colors} n={2} text="Tap “Pair device with pairing code”" />
                  <Step colors={colors} n={3} text="Enter the 6-digit code below" />
                </>
              ) : (
                <Step colors={colors} n={1} text="Turn on Wireless debugging in Developer options" />
              )}
            </Group>

            {mode === 'pair' ? (
              <OutlinedTextField
                ref={codeRef}
                value={codeText}
                onValueChange={onCodeChange}
                singleLine
                enabled={!busy}
                maxLength={CODE_LENGTH}
                shape={radius(16)}
                modifiers={[fillMaxWidth(), graphicsLayer({ translationX: shakeX })]}
                textStyle={{ textAlign: 'center', fontSize: 28, fontWeight: '500', fontFamily: MONO.medium, letterSpacing: 8 }}
                keyboardOptions={{ keyboardType: 'number', imeAction: 'done' }}
              >
                <OutlinedTextField.Label>
                  <Text>Pairing code</Text>
                </OutlinedTextField.Label>
                <OutlinedTextField.Placeholder>
                  <Text>000000</Text>
                </OutlinedTextField.Placeholder>
              </OutlinedTextField>
            ) : null}

            <Row modifiers={[fillMaxWidth()]}>
              <LinkButton
                colors={colors}
                icon={icons.openInNew}
                label="Open Developer Settings"
                enabled={!busy}
                onPress={openSettings}
              />
            </Row>

            <Reveal visible={!!boot.error}>
              <Surface color={colors.errorContainer} shape={radius(20)} modifiers={[fillMaxWidth()]}>
                <Row
                  modifiers={[fillMaxWidth(), padding(16, 14, 16, 14)]}
                  horizontalArrangement={{ spacedBy: 12 }}
                  verticalAlignment="top"
                >
                  <Icon source={icons.error} size={20} tint={colors.onErrorContainer} />
                  <Text modifiers={[weight(1)]} color={colors.onErrorContainer} style={{ typography: 'bodyMedium' }}>
                    {shownError}
                  </Text>
                </Row>
              </Surface>
            </Reveal>
          </Column>

          <Box
            modifiers={[
              fillMaxWidth(),
              padding(Spacing.three, Spacing.two, Spacing.three, insets.bottom + Spacing.three),
            ]}
          >
            <PrimaryButton
              colors={colors}
              label={mode === 'pair' ? 'Pair' : 'Try Again'}
              busy={busy}
              enabled={mode === 'pair' ? canSubmit || busy : true}
              onPress={() => (mode === 'pair' ? boot.pair(code) : boot.refresh())}
            />
          </Box>
        </Column>
    </M3Host>
  );
}

/** One numbered instruction row: a primary bubble in the leading slot. */
function Step({ colors, n, text }: { colors: MaterialColors; n: number; text: string }) {
  return (
    <GroupRow
      colors={colors}
      label={text}
      leading={
        <Surface color={colors.primary} shape={radius(14)} modifiers={[size(28, 28)]}>
          <Box contentAlignment="center" modifiers={[size(28, 28)]}>
            <Text color={colors.onPrimary} style={{ typography: 'labelLarge', fontWeight: '600' }}>
              {n}
            </Text>
          </Box>
        </Surface>
      }
    />
  );
}
