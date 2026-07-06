import { Button, Column, Text, type MaterialColors } from "@expo/ui/jetpack-compose";
import { fillMaxWidth } from "@expo/ui/jetpack-compose/modifiers";

import { type IconSource } from "@/components/icons";
import { IconCircle, tonal, type RowShape, type Tone } from "@/components/m3";
import { Spacing } from "@/constants/theme";

/**
 * Shared vocabulary for the app's modal bottom sheets (the unpair ConfirmSheet and the
 * UpdateModal): the tonal icon badge, the centered headline + consequence line, and the
 * house Button configuration — so every sheet reads as the same M3 design language.
 */

/** Centered headline + consequence line. */
export function SheetText({
  colors,
  title,
  message,
}: {
  colors: MaterialColors;
  title: string;
  message: string;
}) {
  return (
    <Column
      horizontalAlignment="center"
      verticalArrangement={{ spacedBy: Spacing.two }}
    >
      <Text
        color={colors.onSurface}
        style={{
          typography: "headlineSmall",
          fontWeight: "bold",
          textAlign: "center",
        }}
      >
        {title}
      </Text>
      <Text
        color={colors.onSurfaceVariant}
        style={{ typography: "bodyMedium", textAlign: "center" }}
      >
        {message}
      </Text>
    </Column>
  );
}

/** The 56dp tonal icon badge + {@link SheetText}, for sheets with a fixed header. */
export function SheetHeader({
  colors,
  icon,
  tone = "secondary",
  title,
  message,
}: {
  colors: MaterialColors;
  icon: IconSource;
  tone?: Tone;
  title: string;
  message: string;
}) {
  const t = tonal(colors, tone);
  return (
    <>
      <IconCircle
        source={icon}
        container={t.container}
        on={t.on}
        diameter={56}
        iconSize={28}
      />
      <SheetText colors={colors} title={title} message={message} />
    </>
  );
}

/**
 * House sheet button: 14dp vertical content padding, semibold label. Sized with
 * fillMaxWidth fractions (`width`), NOT weight() — weight is ignored on Button inside a
 * ModalBottomSheet and the row falls apart into a stack. Accepts `shape` so it can sit
 * inside a {@link ButtonGroup}.
 */
export function SheetButton({
  colors,
  variant = "filled",
  label,
  onClick,
  width,
  fontSize,
  shape,
}: {
  colors: MaterialColors;
  variant?: "filled" | "tonal" | "destructive" | "text";
  label: string;
  onClick: () => void;
  /** fillMaxWidth fraction (e.g. 0.5, 1); omit for content-sized. */
  width?: number;
  fontSize?: number;
  shape?: RowShape;
}) {
  const palette = {
    filled: { containerColor: colors.primary, contentColor: colors.onPrimary },
    tonal: {
      containerColor: colors.secondaryContainer,
      contentColor: colors.onSecondaryContainer,
    },
    destructive: { containerColor: colors.error, contentColor: colors.onError },
    text: { containerColor: "transparent", contentColor: colors.primary },
  }[variant];
  return (
    <Button
      onClick={onClick}
      colors={palette}
      contentPadding={{ top: 14, bottom: 14 }}
      modifiers={width != null ? [fillMaxWidth(width)] : undefined}
      shape={shape}
    >
      <Text style={{ fontWeight: "600", ...(fontSize != null ? { fontSize } : {}) }}>
        {label}
      </Text>
    </Button>
  );
}
