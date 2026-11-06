import {
  Box,
  Button,
  Icon,
  LoadingIndicator,
  Row,
  Shape,
  Surface,
  type MaterialColors,
} from "@expo/ui/jetpack-compose";
import { Text } from "@/components/text";
import { fillMaxWidth, height, padding, size, weight } from "@expo/ui/jetpack-compose/modifiers";

import type { IconSource } from "@/components/icons";
import { Spacing } from "@/constants/theme";

const radius = (r: number) =>
  Shape.RoundedCorner({ cornerRadii: { topStart: r, topEnd: r, bottomStart: r, bottomEnd: r } });

const PILL = radius(24);

export type ToolTone = "tonal" | "neutral" | "error";

/**
 * A 48dp pill action for a toolbar row (Logs / Daemon log). With a `label` it is a wide pill that
 * shares the row (`grow`); without one it is a 48dp icon-only circle. `busy` swaps the glyph for a
 * spinner and ignores taps; `tonal` = secondary container, `neutral` = surface, `error` = destructive.
 */
export function ToolButton({
  colors,
  icon,
  label,
  tone = "tonal",
  busy,
  grow,
  onPress,
}: {
  colors: MaterialColors;
  icon: IconSource;
  label?: string;
  tone?: ToolTone;
  busy?: boolean;
  grow?: boolean;
  onPress: () => void;
}) {
  const container =
    tone === "tonal"
      ? colors.secondaryContainer
      : tone === "error"
        ? colors.errorContainer
        : colors.surfaceContainerHigh;
  const content =
    tone === "tonal"
      ? colors.onSecondaryContainer
      : tone === "error"
        ? colors.onErrorContainer
        : colors.onSurface;
  return (
    <Surface
      color={container}
      shape={PILL}
      onClick={busy ? undefined : onPress}
      modifiers={label || grow ? [weight(1), height(48)] : [size(48, 48)]}
    >
      <Row
        modifiers={label || grow ? [fillMaxWidth(), height(48)] : [size(48, 48)]}
        horizontalArrangement="center"
        verticalAlignment="center"
      >
        <Row horizontalArrangement={{ spacedBy: Spacing.two }} verticalAlignment="center">
          {busy ? (
            <Box modifiers={[size(22, 22)]} contentAlignment="center">
              <LoadingIndicator color={content} modifiers={[size(22, 22)]} />
            </Box>
          ) : (
            <Icon source={icon} size={20} tint={content} />
          )}
          {label ? (
            <Text color={content} style={{ typography: "labelLarge", fontSize: 15, fontWeight: "500" }}>
              {label}
            </Text>
          ) : null}
        </Row>
      </Row>
    </Surface>
  );
}

/**
 * Full-width 56dp primary action pinned at the bottom of a flow screen (Pair, Try again, Save).
 * `busy` shows a spinner in place of the label and blocks taps; `enabled=false` uses the M3
 * disabled colours.
 */
export function PrimaryButton({
  colors,
  label,
  onPress,
  enabled = true,
  busy,
  icon,
}: {
  colors: MaterialColors;
  label: string;
  onPress: () => void;
  enabled?: boolean;
  busy?: boolean;
  icon?: IconSource;
}) {
  const active = enabled && !busy;
  return (
    <Button
      onClick={active ? onPress : undefined}
      enabled={enabled}
      modifiers={[fillMaxWidth()]}
      contentPadding={{ top: 16, bottom: 16 }}
    >
      {busy ? (
        <Box modifiers={[size(24, 24)]} contentAlignment="center">
          <LoadingIndicator color={colors.onPrimary} modifiers={[size(24, 24)]} />
        </Box>
      ) : (
        <Row horizontalArrangement={{ spacedBy: 10 }} verticalAlignment="center">
          {icon ? <Icon source={icon} size={22} tint={active ? colors.onPrimary : colors.onSurfaceVariant} /> : null}
          <Text
            color={active ? colors.onPrimary : colors.onSurfaceVariant}
            style={{ typography: "labelLarge", fontSize: 16, fontWeight: "500" }}
          >
            {label}
          </Text>
        </Row>
      )}
    </Button>
  );
}

/** Small primary text button with an optional leading glyph (e.g. “Open Developer Settings”). */
export function LinkButton({
  colors,
  label,
  icon,
  onPress,
  enabled = true,
}: {
  colors: MaterialColors;
  label: string;
  icon?: IconSource;
  onPress: () => void;
  enabled?: boolean;
}) {
  return (
    <Button
      onClick={onPress}
      enabled={enabled}
      colors={{ containerColor: "transparent", contentColor: colors.primary }}
      contentPadding={{ top: 8, bottom: 8, start: 12, end: 16 }}
    >
      <Row horizontalArrangement={{ spacedBy: Spacing.two }} verticalAlignment="center" modifiers={[padding(0, 0, 0, 0)]}>
        {icon ? <Icon source={icon} size={18} tint={colors.primary} /> : null}
        <Text color={colors.primary} style={{ typography: "labelLarge", fontWeight: "500" }}>
          {label}
        </Text>
      </Row>
    </Button>
  );
}
