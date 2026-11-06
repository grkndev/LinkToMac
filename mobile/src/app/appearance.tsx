import {
  Box,
  Column,
  FlowRow,
  getMaterialColors,
  Icon,
  Shape,
  EnterTransition,
  ExitTransition,
  type MaterialColors,
} from "@expo/ui/jetpack-compose";
import { Text } from "@/components/text";
import {
  animated,
  background,
  clip,
  fillMaxWidth,
  graphicsLayer,
  Shapes,
  size,
} from "@expo/ui/jetpack-compose/modifiers";
import { useMemo } from "react";
import { useColorScheme } from "react-native";

import { useIcons } from "@/components/icons";
import { ButtonGroup, ModeTile, SectionLabel, useM3Colors } from "@/components/m3";
import { M3Screen } from "@/components/m3-screen";
import { AnimatedSurface, Motion, Reveal } from "@/components/motion";
import { Spacing } from "@/constants/theme";
import {
  COLOR_LABELS,
  SEEDS,
  type ThemeColor,
  type ThemeMode,
} from "@/features/appearance/appearance-store";
import { useAppearance } from "@/features/appearance/appearance-context";
import { haptic } from "@/lib/haptics";

/** 64dp swatch ring: a fully-rounded square reads as a circle. */
const CIRCLE = Shape.RoundedCorner({
  cornerRadii: { topStart: 32, topEnd: 32, bottomStart: 32, bottomEnd: 32 },
});

const MODES: { value: ThemeMode; label: string }[] = [
  { value: "system", label: "System" },
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
];

const FIXED_COLORS = Object.keys(SEEDS) as Exclude<ThemeColor, "dynamic">[];

/**
 * Settings ▸ Appearance: light/dark/system and the accent colour. Both apply live (the whole app
 * recolours behind this screen) and persist immediately — there is no Save button. The colour row
 * offers "System" (the wallpaper palette, Material You) first when the device supports it, then the
 * fixed seeds; each swatch previews that seed's own primary in the *current* light/dark scheme.
 */
export default function AppearanceScreen() {
  const colors = useM3Colors();
  const scheme = useColorScheme() === "dark" ? "dark" : "light";
  const { mode, color, setMode, setColor, dynamicAvailable } = useAppearance();

  const choices: ThemeColor[] = dynamicAvailable ? ["dynamic", ...FIXED_COLORS] : FIXED_COLORS;

  return (
    <M3Screen paddingTop={Spacing.three} spacing={Spacing.three}>
      <SectionLabel colors={colors}>Theme</SectionLabel>
      <ButtonGroup>
        {MODES.map((m) => (
          <ModeTile
            key={m.value}
            colors={colors}
            label={m.label}
            selected={mode === m.value}
            onPress={() => {
              if (m.value !== mode) haptic();
              setMode(m.value);
            }}
          />
        ))}
      </ButtonGroup>

      <SectionLabel colors={colors}>Color</SectionLabel>
      <FlowRow
        modifiers={[fillMaxWidth()]}
        horizontalArrangement={{ spacedBy: Spacing.three }}
        verticalArrangement={{ spacedBy: Spacing.three }}
      >
        {choices.map((c) => (
          <Swatch
            key={c}
            colors={colors}
            choice={c}
            scheme={scheme}
            selected={color === c}
            onPress={() => {
              if (c !== color) haptic();
              setColor(c);
            }}
          />
        ))}
      </FlowRow>

      <Text color={colors.onSurfaceVariant} style={{ typography: "bodyMedium" }}>
        {dynamicAvailable
          ? "System uses the colors from your wallpaper. Pick a color to use the same one everywhere."
          : "Pick the accent color used across the app."}
      </Text>
    </M3Screen>
  );
}

const POP_IN = EnterTransition.scaleIn({ initialScale: 0.4 }).plus(EnterTransition.fadeIn());
const POP_OUT = ExitTransition.scaleOut({ targetScale: 0.4 }).plus(ExitTransition.fadeOut());

/** A 64dp circular colour choice with its label; the selected one carries a check and a ring. */
function Swatch({
  colors,
  choice,
  scheme,
  selected,
  onPress,
}: {
  colors: MaterialColors;
  choice: ThemeColor;
  scheme: "light" | "dark";
  selected: boolean;
  onPress: () => void;
}) {
  const icons = useIcons();
  const dynamic = choice === "dynamic";
  // Preview the choice's own palette so the swatch is correct whatever colour is active now.
  // (`getMaterialColors` is a cheap synchronous native call; the grid is at most 6 swatches.)
  const palette = useMemo(
    () => getMaterialColors({ scheme, seedColor: dynamic ? undefined : SEEDS[choice] }),
    [scheme, dynamic, choice],
  );
  const fill = dynamic ? palette.secondaryContainer : palette.primary;
  const onFill = dynamic ? palette.onSecondaryContainer : palette.onPrimary;

  return (
    <Column
      horizontalAlignment="center"
      verticalArrangement={{ spacedBy: Spacing.one }}
      modifiers={[size(72, 92)]}
    >
      <AnimatedSurface
        color={selected ? colors.primary : colors.surfaceContainerHigh}
        shape={CIRCLE}
        onClick={onPress}
        modifiers={[size(64, 64)]}
      >
        <Box contentAlignment="center" modifiers={[size(64, 64)]}>
          <Box
            contentAlignment="center"
            modifiers={[
              size(56, 56),
              // Selected = a ring: the dot shrinks 56 → 52 with a spring. Layer first, so the
              // clip and fill are inside the scaled layer.
              graphicsLayer({
                scaleX: animated(selected ? 52 / 56 : 1, Motion.spatial),
                scaleY: animated(selected ? 52 / 56 : 1, Motion.spatial),
              }),
              clip(Shapes.Circle),
              background(fill),
            ]}
          >
            <Reveal visible={selected} enter={POP_IN} exit={POP_OUT}>
              <Icon source={icons.check} size={26} tint={onFill} />
            </Reveal>
            <Reveal visible={!selected && dynamic} enter={POP_IN} exit={POP_OUT}>
              <Icon source={icons.wallpaper} size={26} tint={onFill} />
            </Reveal>
          </Box>
        </Box>
      </AnimatedSurface>
      <Text
        color={selected ? colors.onSurface : colors.onSurfaceVariant}
        style={{ typography: "labelMedium", fontWeight: selected ? "700" : "500", textAlign: "center" }}
      >
        {COLOR_LABELS[choice]}
      </Text>
    </Column>
  );
}
